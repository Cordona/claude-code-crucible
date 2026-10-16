#!/usr/bin/env sh
# Prints one tab-separated line per installed plugin under the skills dir: a
# tech plugin (tech-<stack>/) or a standard plugin (standard-<area>/ whose
# SKILL.md sets disable-model-invocation: true), with its full folder name,
# label, description and files in load order. The main thread picks plugins by
# their descriptions and copies the names and labels into its plan;
# render-plugin-line.sh copies the paths into the brief. A plugin that fails
# inject-plugins.sh's plugin test (name, disable-model-invocation, closed
# frontmatter) or lacks a label or description is reported on stderr instead of
# listed (a `standard-*` folder whose closed frontmatter lacks
# `disable-model-invocation: true` is not a plugin: skipped, never reported as
# invalid), as is one whose path holds a comma or control character, which
# would split the PLUGIN line or a plugin line; the hook's file checks still run
# at dispatch.
set -eu

readonly PROG='list-plugins.sh'
readonly REQUIRED_TOOLS='awk sort'
# The C locale makes awk and sort byte-wise and identical on every platform; the
# parsing only matches ASCII, so UTF-8 labels pass through unchanged.
LC_ALL=C
export LC_ALL
TAB=$(printf '\t')
readonly TAB
readonly NO_FRONTMATTER_ERROR='SKILL.md has no frontmatter; expected a --- block opening on line 1 and closed by ---; reinstall the plugin'
readonly NO_LABEL_ERROR='SKILL.md has no metadata.label; expected a "  label:" line under "metadata:" in the frontmatter; reinstall the plugin'
readonly NO_DESCRIPTION_ERROR='SKILL.md has no readable description; expected a non-empty description: in the frontmatter, plain, quoted or a > or | block; fix the description or reinstall the plugin'
# Keeps the listing a bounded read for the main thread; well above any real install.
readonly DEFAULT_MAX_LINES=200

# Prints "<label>\t<base>\t<disable-model-invocation>\t<name>\t<description>"
# from the YAML frontmatter, name and disable-model-invocation read as
# inject-plugins.sh reads them; exits 2 when the file has no closed frontmatter.
# The description may be plain (one line or indented continuation lines),
# single- or double-quoted, or a > or | block; its lines are joined by single
# spaces and every control character becomes a space. A form it can't read
# (a flow collection, an alias, a tag, an unclosed quote, a double-quoted
# escape other than \" \\ \/ \n \t \r or "\ ") prints an empty description.
# The program is single-quoted on purpose: its $0 is awk's, not the shell's.
# shellcheck disable=SC2016
readonly FRONTMATTER_AWK='
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
function trim(value) {
	sub(/^[ \t]+/, "", value)
	sub(/[ \t]+$/, "", value)
	return value
}
function start_description(value) {
	value = trim(value)
	description_parts = ""
	plain_ended = 0
	collecting = 1
	if (value ~ /^[>|]/) {
		description_kind = (value ~ /^[>|]([-+][1-9]?|[1-9][-+]?)?([ \t]+#.*)?$/) ? "block" : "unreadable"
		return
	}
	if (value ~ /^["\047]/) {
		description_kind = "quoted"
		description_parts = value
		return
	}
	if (value ~ /^([][{}&*!%@`,]|[-?:]([ \t]|$))/) {
		description_kind = "unreadable"
		return
	}
	description_kind = "plain"
	add_plain_line(value)
}
function add_part(value) {
	if (value != "") description_parts = description_parts (description_parts == "" ? "" : " ") value
}
function add_plain_line(value) {
	if (plain_ended) return
	if (value ~ /^#/) { plain_ended = 1; return }
	if (sub(/[ \t]+#.*$/, "", value)) plain_ended = 1
	add_part(value)
}
function continue_description(value) {
	value = trim(value)
	if (description_kind == "plain") add_plain_line(value)
	else if (description_kind != "unreadable") add_part(value)
}
function finish_description(  value) {
	collecting = 0
	if (description_kind == "plain" || description_kind == "block") value = description_parts
	else if (description_kind == "quoted") value = unquote(description_parts)
	else value = ""
	gsub(/[[:cntrl:]]/, " ", value)
	description = trim(value)
}
# Returns the text inside the quoted scalar that opens value, or "" when it is
# unclosed, holds an escape it cannot map, or has more than a comment after it.
function unquote(value,  quote, out, i, n, c, next_c) {
	quote = substr(value, 1, 1)
	n = length(value)
	out = ""
	for (i = 2; i <= n; i++) {
		c = substr(value, i, 1)
		next_c = substr(value, i + 1, 1)
		if (quote == "\047" && c == "\047" && next_c == "\047") { out = out c; i++; continue }
		if (c == quote) return (substr(value, i + 1) ~ /^([ \t]+(#.*)?)?$/) ? out : ""
		if (quote == "\"" && c == "\\") {
			if (next_c ~ /^["\\\/]$/) out = out next_c
			else if (next_c ~ /^[ntr ]$/) out = out " "
			else return ""
			i++
			continue
		}
		out = out c
	}
	return ""
}
{ sub(/\r$/, "") }
NR == 1 { if ($0 != "---") exit; next }
$0 == "---" { closed = 1; exit }
collecting && /^([ \t]|$)/ { continue_description($0); next }
collecting { finish_description() }
/^description:/ { in_metadata = 0; start_description(substr($0, index($0, ":") + 1)); next }
/^disable-model-invocation:/ {
	in_metadata = 0
	model_invocation_disabled = clean(substr($0, index($0, ":") + 1))
	next
}
/^name:/ { in_metadata = 0; name = clean(substr($0, index($0, ":") + 1)); next }
/^[^ \t#]/ { in_metadata = ($0 ~ /^metadata:[ \t]*(#.*)?$/); next }
in_metadata && /^  label:/ { label = clean(substr($0, index($0, ":") + 1)) }
in_metadata && /^  base:/ { base = clean(substr($0, index($0, ":") + 1)) }
END {
	if (!closed) exit 2
	if (collecting) finish_description()
	printf "%s\t%s\t%s\t%s\t%s\n", label, base, model_invocation_disabled, name, description
}
'

usage() {
	cat <<EOF
Usage: ${PROG} [--skills-dir DIR] [--max-lines N] [--help|-h]

Lists the installed plugins under DIR. DIR defaults to \$CLAUDE_CONFIG_DIR/skills
when CLAUDE_CONFIG_DIR is set, else \$HOME/.claude/skills.
  tech plugin:     DIR/tech-<stack>/ holding SKILL.md and references/development.md;
                   metadata.base may name one other tech plugin by its <stack>
                   (e.g. typescript for tech-typescript), loaded first.
  standard plugin: DIR/standard-<area>/ whose SKILL.md frontmatter has
                   disable-model-invocation: true, plus references/development.md;
                   it takes no metadata.base. A standard-* folder whose closed
                   frontmatter lacks that line is not a plugin and is skipped.
A plugin (and a tech plugin's base) is valid only when its SKILL.md frontmatter
is closed by ---, has name: <its folder name> and disable-model-invocation: true,
the test inject-plugins.sh applies, plus a metadata.label and a description,
and only when its path (DIR included) holds no comma or control character, so
the PLUGIN line and the plugin line can carry it; one that fails is reported
as invalid.

Output (stdout), one line per valid plugin, TAB-separated, tech lines first,
then standard lines, each sorted by NAME:
  <KIND> <NAME> <label> <description> [<base SKILL.md> <base development.md>] <SKILL.md> <development.md>
KIND is tech or standard; NAME is the plugin's full folder name (tech-shell,
standard-clean-code); the label is metadata.label; the description is the
frontmatter description (plain, quoted, or a > or | block) on one field, its
tabs and line breaks turned into single spaces. The paths start at field 5.
A description that is missing, empty or in a form this script can't read
makes the plugin invalid.
Each invalid plugin gets one stderr line: ${PROG}: <NAME>: <reason>

--max-lines N prints at most N plugin lines, in the order above (default
${DEFAULT_MAX_LINES}; 0 prints all). When lines are cut, one stderr line says so:
  ${PROG}: TRUNCATED: showing N of M plugin lines; pass --max-lines 0 for all

Exit codes (a cut listing keeps its code):
  0  at least one plugin printed, none invalid
  1  no plugin of either kind under DIR
  2  usage error, or DIR missing or unreadable
  3  one or more invalid plugins (valid ones are still printed)
  5  a required tool is missing from PATH

Dependencies: POSIX sh, awk, sort; checked at start, a missing one exits 5.
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Sets fm_label, fm_base, fm_disabled, fm_name and fm_description from the
# FRONTMATTER_AWK output in $frontmatter.
split_frontmatter() {
	fm_label=${frontmatter%%"${TAB}"*}
	frontmatter_rest=${frontmatter#*"${TAB}"}
	fm_base=${frontmatter_rest%%"${TAB}"*}
	frontmatter_rest=${frontmatter_rest#*"${TAB}"}
	fm_disabled=${frontmatter_rest%%"${TAB}"*}
	frontmatter_rest=${frontmatter_rest#*"${TAB}"}
	fm_name=${frontmatter_rest%%"${TAB}"*}
	fm_description=${frontmatter_rest#*"${TAB}"}
}

# Prints the error for a plugin folder $1 whose frontmatter fails the test
# inject-plugins.sh applies (name: <folder name>, disable-model-invocation:
# true); prints nothing when it passes.
plugin_test_error() {
	if [ "${fm_name}" != "$1" ]; then
		printf "SKILL.md has name: '%s'; expected name: %s, its folder name; fix the name or reinstall the plugin" "${fm_name}" "$1"
	elif [ "${fm_disabled}" != true ]; then
		printf 'SKILL.md lacks disable-model-invocation: true; expected it in the frontmatter of every plugin; reinstall the plugin'
	fi
}

# Sets plugin_label, plugin_description, plugin_base and plugin_error for
# tech-$1 (error empty when valid).
inspect_tech() {
	plugin_dir="${skills_dir}/tech-$1"
	plugin_label=''
	plugin_description=''
	plugin_base=''
	plugin_error=''
	if [ ! -f "${plugin_dir}/SKILL.md" ]; then
		plugin_error=$(missing_file_error "${plugin_dir}" SKILL.md)
	elif [ ! -f "${plugin_dir}/references/development.md" ]; then
		plugin_error=$(missing_file_error "${plugin_dir}" references/development.md)
	elif ! frontmatter=$(awk "${FRONTMATTER_AWK}" "${plugin_dir}/SKILL.md"); then
		plugin_error=${NO_FRONTMATTER_ERROR}
	else
		split_frontmatter
		plugin_label=${fm_label}
		plugin_description=${fm_description}
		plugin_base=${fm_base}
		plugin_error=$(plugin_test_error "tech-$1")
		[ -n "${plugin_error}" ] || [ -n "${plugin_label}" ] || plugin_error=${NO_LABEL_ERROR}
		[ -n "${plugin_error}" ] || [ -n "${plugin_description}" ] || plugin_error=${NO_DESCRIPTION_ERROR}
	fi
}

# Prints the error for plugin folder $1 when its path holds a comma or a
# control character: the hook splits the PLUGIN line on commas, and a tab or a
# line break would split a plugin line. Prints nothing for a safe path.
unsafe_path_error() {
	case ${skills_dir} in
		*,* | *[[:cntrl:]]*)
			printf 'skills folder path %s holds a comma or control character; expected a path the PLUGIN line can carry; move the skills folder (CLAUDE_CONFIG_DIR) or pass --skills-dir DIR' "${skills_dir}"
			return 0
			;;
		*) ;;
	esac
	case $1 in
		*,* | *[[:cntrl:]]*)
			printf 'folder name holds a comma or control character; expected a name the PLUGIN line can carry; rename the folder and reinstall the plugin'
			;;
		*) ;;
	esac
}

# Prints the error for a missing file $2 of the plugin in folder $1.
missing_file_error() {
	printf '%s is missing; expected %s; reinstall the plugin' "$2" "$1/$2"
}

plugin_paths() {
	printf '%s\t%s' "${skills_dir}/$1/SKILL.md" "${skills_dir}/$1/references/development.md"
}

# Sets plugin_line for tech-$1, or line_error when it or its base is invalid.
build_tech_line() {
	plugin_line=''
	line_error=$(unsafe_path_error "tech-$1")
	[ -z "${line_error}" ] || return 0
	inspect_tech "$1"
	if [ -n "${plugin_error}" ]; then
		line_error=${plugin_error}
		return 0
	fi
	label=${plugin_label}
	description=${plugin_description}
	base=${plugin_base}
	own_paths=$(plugin_paths "tech-$1")
	if [ -z "${base}" ]; then
		plugin_line="tech${TAB}tech-$1${TAB}${label}${TAB}${description}${TAB}${own_paths}"
		return 0
	fi
	case ${base} in
		*/* | *"${TAB}"*)
			line_error="metadata.base '${base}' is not a plugin name; expected a <stack> such as typescript; fix metadata.base or reinstall the plugin"
			return 0
			;;
		*) ;;
	esac
	if [ ! -d "${skills_dir}/tech-${base}" ]; then
		line_error="base '${base}' has no plugin folder; expected ${skills_dir}/tech-${base}/; install tech-${base} or reinstall the plugin"
		return 0
	fi
	base_path_error=$(unsafe_path_error "tech-${base}")
	if [ -n "${base_path_error}" ]; then
		line_error="base '${base}' is invalid: ${base_path_error}"
		return 0
	fi
	inspect_tech "${base}"
	if [ -n "${plugin_error}" ]; then
		line_error="base '${base}' is invalid: ${plugin_error}"
	elif [ -n "${plugin_base}" ]; then
		line_error="base '${base}' itself has a base ('${plugin_base}'); expected a base without metadata.base; reinstall both plugins"
	else
		base_paths=$(plugin_paths "tech-${base}")
		plugin_line="tech${TAB}tech-$1${TAB}${label}${TAB}${description}${TAB}${base_paths}${TAB}${own_paths}"
	fi
}

# Sets is_plugin=true for a standard plugin standard-$1, then plugin_line, or
# line_error when it is invalid. Without a SKILL.md or a closed frontmatter the
# opt-in line can't be read, so the folder counts as an invalid plugin; a closed
# frontmatter without the opt-in line is not a plugin.
build_standard_line() {
	plugin_dir="${skills_dir}/standard-$1"
	is_plugin=true
	plugin_line=''
	line_error=''
	if [ ! -f "${plugin_dir}/SKILL.md" ]; then
		line_error=$(missing_file_error "${plugin_dir}" SKILL.md)
		return 0
	fi
	if ! frontmatter=$(awk "${FRONTMATTER_AWK}" "${plugin_dir}/SKILL.md"); then
		line_error=${NO_FRONTMATTER_ERROR}
		return 0
	fi
	split_frontmatter
	if [ "${fm_disabled}" != true ]; then
		is_plugin=false
		return 0
	fi
	line_error=$(unsafe_path_error "standard-$1")
	[ -z "${line_error}" ] || return 0
	line_error=$(plugin_test_error "standard-$1")
	[ -z "${line_error}" ] || return 0
	if [ ! -f "${plugin_dir}/references/development.md" ]; then
		line_error=$(missing_file_error "${plugin_dir}" references/development.md)
	elif [ -z "${fm_label}" ]; then
		line_error=${NO_LABEL_ERROR}
	elif [ -z "${fm_description}" ]; then
		line_error=${NO_DESCRIPTION_ERROR}
	elif [ -n "${fm_base}" ]; then
		line_error="a standard plugin takes no metadata.base ('${fm_base}'); expected no base key; remove metadata.base or reinstall the plugin"
	else
		plugin_line="standard${TAB}standard-$1${TAB}${fm_label}${TAB}${fm_description}${TAB}$(plugin_paths "standard-$1")"
	fi
}

# Records the outcome of a build_*_line call for plugin $1-$2.
record_line() {
	if [ -n "${line_error}" ]; then
		report=$(one_line "$1-$2: ${line_error}")
		warn "${report}"
		invalid_any=true
		return 0
	fi
	line_count=$((line_count + 1))
	if [ "$1" = tech ]; then
		tech_lines="${tech_lines}${plugin_line}
"
	else
		standard_lines="${standard_lines}${plugin_line}
"
	fi
}

# Prints $1 with each control character as "?", so a stderr report stays one line.
one_line() {
	case $1 in
		*[[:cntrl:]]*) printf '%s' "$1" | awk '{ gsub(/[[:cntrl:]]/, "?"); printf "%s%s", separator, $0; separator = "?" }' ;;
		*) printf '%s' "$1" ;;
	esac
}

print_sorted() {
	[ -z "$1" ] || printf '%s' "$1" | sort
}

# Sets max_lines from the --max-lines value $1, a decimal integer of any length.
# Leading zeros are dropped so arithmetic never reads the value as octal.
parse_max_lines() {
	case $1 in
		'' | *[!0-9]*) usage_error "--max-lines value '$1' is not a non-negative integer; expected --max-lines N such as 50, or 0 for all" ;;
		*) ;;
	esac
	max_lines=$1
	while :; do
		case ${max_lines} in
			0?*) max_lines=${max_lines#0} ;;
			*) break ;;
		esac
	done
}

# Warns when max_lines cut the listing. Compares digit counts first, so an N
# too long for shell arithmetic never reaches a numeric test.
warn_if_truncated() {
	[ "${max_lines}" != 0 ] || return 0
	[ "${#max_lines}" -le "${#line_count}" ] || return 0
	[ "${max_lines}" -lt "${line_count}" ] || return 0
	warn "TRUNCATED: showing ${max_lines} of ${line_count} plugin lines; pass --max-lines 0 for all"
}

for tool in ${REQUIRED_TOOLS}; do
	command -v "${tool}" >/dev/null 2>&1 ||
		die 5 "${tool} missing; expected it on PATH; install your base system's ${tool}"
done

skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
max_lines=${DEFAULT_MAX_LINES}
while [ "$#" -gt 0 ]; do
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		--skills-dir)
			[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--skills-dir needs a DIR value; expected --skills-dir DIR'
			skills_dir=$2
			shift 2
			;;
		--max-lines)
			[ "$#" -ge 2 ] || usage_error '--max-lines needs an N value; expected --max-lines N'
			parse_max_lines "$2"
			shift 2
			;;
		*) usage_error "unknown option: $1; expected --skills-dir DIR, --max-lines N or --help" ;;
	esac
done

case ${skills_dir} in
	/* | [A-Za-z]:[\\/]*) ;;
	*) skills_dir="${PWD}/${skills_dir#./}" ;;
esac
while [ "${skills_dir}" != '/' ] && [ "${skills_dir%/}" != "${skills_dir}" ]; do
	skills_dir=${skills_dir%/}
done

[ -d "${skills_dir}" ] && [ -r "${skills_dir}" ] && [ -x "${skills_dir}" ] ||
	die 2 "skills dir missing or unreadable: ${skills_dir}; expected a readable skills folder; set CLAUDE_CONFIG_DIR or pass --skills-dir DIR"

found_any=false
invalid_any=false
line_count=0
tech_lines=''
standard_lines=''
for plugin_path in "${skills_dir}"/tech-*; do
	[ -d "${plugin_path}" ] || continue
	found_any=true
	name=${plugin_path##*/tech-}
	build_tech_line "${name}"
	record_line tech "${name}"
done
for plugin_path in "${skills_dir}"/standard-*; do
	[ -d "${plugin_path}" ] || continue
	name=${plugin_path##*/standard-}
	build_standard_line "${name}"
	[ "${is_plugin}" = true ] || continue
	found_any=true
	record_line standard "${name}"
done

[ "${found_any}" = true ] || die 1 "no plugins under ${skills_dir}; expected tech-<stack>/ or standard-<area>/ folders; install the plugins or check --skills-dir"
{
	print_sorted "${tech_lines}"
	print_sorted "${standard_lines}"
} | awk -v max="${max_lines}" 'max == 0 || NR <= max'
warn_if_truncated
[ "${invalid_any}" = false ] || exit 3
