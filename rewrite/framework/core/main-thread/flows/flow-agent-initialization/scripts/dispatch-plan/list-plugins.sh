#!/usr/bin/env sh
# Prints one tab-separated line per installed plugin under the skills dir: a
# tech plugin (tech-<stack>/), a standard plugin (standard-<area>/) or a
# procedure plugin (procedure-<name>/), the last two only when their SKILL.md
# sets disable-model-invocation: true, with its full folder name,
# label, description and files in load order. The main thread picks plugins by
# their descriptions and passes their names to generate-dispatch-plan.sh, which
# computes the technology label; generate-agent-dispatch.sh copies the paths
# into the dispatch. A plugin is reported on stderr instead of listed when it
# lacks SKILL.md or references/development.md, fails prepare-agent-prompt.sh's
# plugin test (name, disable-model-invocation, closed frontmatter), lacks a
# label or description, or has a path holding a comma or control character (a
# tab or a line break would split a plugin line); so is a tech plugin whose
# metadata.base is not a plugin name, has no folder, is itself invalid or has
# its own base, and a standard or procedure plugin that sets metadata.base. A
# `standard-*` or `procedure-*` folder is a plugin only when its readable
# SKILL.md has a closed frontmatter with `disable-model-invocation: true`; any
# other is skipped, never reported as invalid. The hook's file checks still run
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
# prepare-agent-prompt.sh reads them; exits 2 when the file has no closed frontmatter.
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
	print_page <<EOF
usage: sh ${PROG} [--skills-dir DIR] [--max-lines N]
       sh ${PROG} --help | -h

Lists the plugins installed in the skills folder, one line each, to pick from.

Options:
  --skills-dir DIR  the skills folder; default
                    \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills; a relative
                    DIR is taken from the current folder
  --max-lines N     print at most N plugin lines; default ${DEFAULT_MAX_LINES}, 0 prints all

Plugins, by folder in DIR:
  tech       tech-<stack>/ with SKILL.md and references/development.md;
             metadata.base may name one other tech plugin by its <stack>
             (typescript for tech-typescript), itself with no metadata.base,
             whose files load first
  standard   standard-<area>/ with SKILL.md and references/development.md,
             opted in by disable-model-invocation: true in its frontmatter;
             no metadata.base. A standard-* folder without a readable
             SKILL.md, or whose SKILL.md has no closed frontmatter with that
             line, is not a plugin: skipped, never reported
  procedure  procedure-<name>/, as a standard plugin
A plugin, and a tech plugin's base, is valid when its SKILL.md frontmatter is
  closed by --- and has name: <its folder name> and disable-model-invocation:
  true (prepare-agent-prompt.sh's plugin test), a metadata.label and a
  readable description, and its path, DIR included, holds no comma or
  control character; any other is invalid.

stdout: one line per valid plugin, TAB-separated, tech lines first, then
  standard, then procedure, each group sorted by NAME:
  <KIND> <NAME> <label> <description> [<base SKILL.md> <base development.md>] <SKILL.md> <development.md>
  KIND tech, standard or procedure; NAME the folder name (tech-shell); label
  metadata.label; description on one field, its tabs and line breaks as
  spaces; the paths absolute, from field 5, a tech plugin's base first
stderr: one "${PROG}: <NAME>: <reason>" line per invalid plugin

stderr on exits 0, 3: "${PROG}: TRUNCATED: showing N of M plugin lines; pass --max-lines 0 for all"
  the listing was cut; show the output and stop

Exit codes:
  0  plugins listed, none invalid; use the lines
  1  no plugin in DIR; go on without plugins
  2  usage error, or DIR missing or unreadable; show stderr and stop
  3  some plugins invalid, the valid ones still listed; fix or reinstall each
     one stderr names
  5  a tool missing; show stderr and stop

Dependencies: POSIX sh, awk, sort (every macOS and Linux base system).
EOF
}

# Prints stdin with builtins only, so the page needs no tool.
print_page() {
	while IFS= read -r page_line; do
		printf '%s\n' "${page_line}"
	done
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
# prepare-agent-prompt.sh applies (name: <folder name>, disable-model-invocation:
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
# control character; a tab or a line break would split a plugin line. Prints
# nothing for a safe path.
unsafe_path_error() {
	case ${skills_dir} in
		*,* | *[[:cntrl:]]*)
			printf 'skills folder path %s holds a comma or control character; expected a path with no comma or control character; move the skills folder (CLAUDE_CONFIG_DIR) or pass --skills-dir DIR' "${skills_dir}"
			return 0
			;;
		*) ;;
	esac
	case $1 in
		*,* | *[[:cntrl:]]*)
			printf 'folder name holds a comma or control character; expected a name with no comma or control character; rename the folder and reinstall the plugin'
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

# Sets is_plugin=true for a plugin $1-$2 of kind $1 (standard or procedure),
# then plugin_line, or line_error when it is invalid. Only the opt-in line
# makes such a folder a plugin, so one without a readable SKILL.md, a closed
# frontmatter or that line is not a plugin: an ordinary skill's folder must
# never stop the listing.
build_opt_in_line() {
	plugin_dir="${skills_dir}/$1-$2"
	is_plugin=false
	plugin_line=''
	line_error=''
	[ -f "${plugin_dir}/SKILL.md" ] && [ -r "${plugin_dir}/SKILL.md" ] || return 0
	frontmatter=$(awk "${FRONTMATTER_AWK}" "${plugin_dir}/SKILL.md") || return 0
	split_frontmatter
	[ "${fm_disabled}" = true ] || return 0
	is_plugin=true
	line_error=$(unsafe_path_error "$1-$2")
	[ -z "${line_error}" ] || return 0
	line_error=$(plugin_test_error "$1-$2")
	[ -z "${line_error}" ] || return 0
	if [ ! -f "${plugin_dir}/references/development.md" ]; then
		line_error=$(missing_file_error "${plugin_dir}" references/development.md)
	elif [ -z "${fm_label}" ]; then
		line_error=${NO_LABEL_ERROR}
	elif [ -z "${fm_description}" ]; then
		line_error=${NO_DESCRIPTION_ERROR}
	elif [ -n "${fm_base}" ]; then
		line_error="a $1 plugin takes no metadata.base ('${fm_base}'); expected no base key; remove metadata.base or reinstall the plugin"
	else
		plugin_line="$1${TAB}$1-$2${TAB}${fm_label}${TAB}${fm_description}${TAB}$(plugin_paths "$1-$2")"
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
	case $1 in
		tech) tech_lines="${tech_lines}${plugin_line}
" ;;
		standard) standard_lines="${standard_lines}${plugin_line}
" ;;
		*) procedure_lines="${procedure_lines}${plugin_line}
" ;;
	esac
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

# Lists every opt-in plugin folder of kind $1 (standard or procedure); a folder
# without the opt-in line is skipped.
scan_opt_in_kind() {
	for plugin_path in "${skills_dir}/$1"-*; do
		[ -d "${plugin_path}" ] || continue
		name=${plugin_path##*/"$1"-}
		build_opt_in_line "$1" "${name}"
		[ "${is_plugin}" = true ] || continue
		found_any=true
		record_line "$1" "${name}"
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

for tool in ${REQUIRED_TOOLS}; do
	command -v "${tool}" >/dev/null 2>&1 ||
		die 5 "${tool} missing; expected it on PATH; install your base system's ${tool}"
done

# A relative DIR is taken from the current folder, so every printed path is
# absolute; trailing slashes are dropped from every DIR.
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
procedure_lines=''
for plugin_path in "${skills_dir}"/tech-*; do
	[ -d "${plugin_path}" ] || continue
	found_any=true
	name=${plugin_path##*/tech-}
	build_tech_line "${name}"
	record_line tech "${name}"
done
scan_opt_in_kind standard
scan_opt_in_kind procedure

[ "${found_any}" = true ] || die 1 "no plugins under ${skills_dir}; expected tech-<stack>/, standard-<area>/ or procedure-<name>/ folders; install the plugins or check --skills-dir"
{
	print_sorted "${tech_lines}"
	print_sorted "${standard_lines}"
	print_sorted "${procedure_lines}"
} | awk -v max="${max_lines}" 'max == 0 || NR <= max'
warn_if_truncated
[ "${invalid_any}" = false ] || exit 3
