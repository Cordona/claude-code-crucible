#!/usr/bin/env sh
# Prints the brief's PLUGIN line for the approved plugin names, with the paths
# taken from list-plugins.sh's plugin lines in load order, so the main thread
# never types or orders a path; --labels prints the plugins' LABELS line instead.
set -eu

readonly PROG='render-plugin-line.sh'
readonly REQUIRED_TOOLS='awk cat mktemp rm'
readonly TESTING_PLUGIN='standard-testing'
# The C locale makes awk byte-wise and identical on every platform.
LC_ALL=C
export LC_ALL

# Reads list-plugins.sh's lines on stdin and the requested names as operands;
# prints the PLUGIN paths one per line in load order (want=paths), or the
# LABELS line with the standard labels in that order (want=labels); or one
# stderr line per problem and exit 3. A plugin line is <kind> <name> <label> <description>
# <paths...>, so the paths start at field 5. The names are taken out of ARGV
# so awk reads stdin.
# The program is single-quoted on purpose: its $ signs are awk's.
# shellcheck disable=SC2016
readonly SELECT_AWK='
function shown(name) { gsub(/[[:cntrl:]]/, "?", name); return name }
function problem(text) { printf "%s: %s\n", prog, text > "/dev/stderr"; failed = 1 }
function add_label(list, label) { return list (list == "" ? "" : ", ") shown(label) }
BEGIN {
	FS = "\t"
	for (i = 1; i < ARGC; i++) {
		name = ARGV[i]
		delete ARGV[i]
		if (name in requested) {
			if (!(name in reported_twice)) problem("name " shown(name) " given twice; expected each plugin once; drop the repeat")
			reported_twice[name] = 1
			continue
		}
		requested[name] = 1
		order[++count] = name
	}
}
!($2 in requested) { next }
{
	installed[$2] = 1
	paths = ""
	for (i = 5; i <= NF; i++) paths = paths $i "\n"
}
$1 == "tech" { tech_count++; tech_names = tech_names (tech_names == "" ? "" : ", ") $2; tech_paths = paths; tech_label = shown($3); next }
$2 == testing { testing_paths = paths; testing_label = $3; next }
{ standard_paths = standard_paths paths; standard_labels = add_label(standard_labels, $3) }
END {
	for (i = 1; i <= count; i++)
		if (!(order[i] in installed))
			problem("name " shown(order[i]) " is not an installed plugin; expected a <NAME> that list-plugins.sh prints, such as tech-shell or standard-security; run list-plugins.sh --max-lines 0 to see them")
	if (tech_count > 1)
		problem("more than one tech plugin named (" shown(tech_names) "); expected at most one; keep the one for this task")
	if (mode == "TEST" && !(testing in requested))
		problem("--mode TEST without " testing "; expected " testing " among the names; add it")
	if (mode == "BUILD" && (testing in requested))
		problem("--mode BUILD with " testing "; expected it only on --mode TEST; drop it or use --mode TEST")
	if (failed) exit 3
	if (want == "labels") {
		if (mode == "TEST") standard_labels = add_label(standard_labels, testing_label)
		printf "LABELS: Technology: %s \302\267 Used standards: %s\n", (tech_label == "" ? "none" : tech_label), (standard_labels == "" ? "none" : standard_labels)
		exit 0
	}
	printf "%s%s", tech_paths, standard_paths
	if (mode == "TEST") printf "%s", testing_paths
}
'

usage() {
	cat <<EOF
Usage: sh ${PROG} --role developer|reviewer --mode BUILD|TEST [--skills-dir DIR] [--labels] [--] [NAME ...]

Prints one line, "PLUGIN: " and the paths of the named plugins joined by ", ",
or "PLUGIN: none" for zero names on --mode BUILD.
With --labels it prints, instead of the PLUGIN line, one line, "LABELS: " and
the same names' labels (list-plugins.sh's label field, a control character as "?"):
  LABELS: Technology: <tech label, or none> · Used standards: <labels, or none>
the standard labels joined by ", " in the PLUGIN line's order (${TESTING_PLUGIN}
last on --mode TEST). The checks and exit codes are the same as without it.
  NAME  an installed plugin's full name as list-plugins.sh prints it (tech-shell,
        standard-security). At most one tech name; no name twice; --mode TEST
        needs ${TESTING_PLUGIN}, --mode BUILD must not have it.
  DIR   the skills folder, as list-plugins.sh's --skills-dir; defaults to
        \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills.

It runs DIR/procedure-agent-initialization/scripts/list-plugins.sh --max-lines 0
and copies paths from its plugin lines, in this order: the tech plugin's paths
as its line prints them (its base's paths first), each named standard in
plugin-line order, then ${TESTING_PLUGIN} last on --mode TEST.
--role reviewer turns each references/development.md into references/review.md
and drops a review.md that is not a readable file. --role developer keeps the
paths as printed and adds, right after each references/development.md, every
readable references/*-template.md file of that plugin, sorted by name (a
template name holding a comma or control character exits 3).

Exit codes:
  0  the line printed
  2  usage error
  3  a name or mode problem (one stderr line each, nothing on stdout),
     invalid plugins reported by list-plugins.sh (its stderr is printed), a
     listing list-plugins.sh reports as TRUNCATED (its stderr is printed), or
     a template name the line can't carry
  4  list-plugins.sh missing
  5  a required tool missing, an awk failure, or no temp file could be made
  6  list-plugins.sh failed with an exit other than 0, 1 or 3, such as 2
     (skills folder missing or unreadable); its stderr and exit are printed
  129, 130, 143  stopped by HUP, INT or TERM; the temp file is removed

Dependencies: POSIX sh, awk, cat, mktemp, rm; checked at start, a missing one exits 5.
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

# shellcheck disable=SC2329 # invoked by the EXIT trap
remove_stderr_file() {
	[ -z "${stderr_file}" ] || rm -f "${stderr_file}"
}

# Sets role, mode, skills_dir, want and the positional names from the arguments.
# Callers run it as: parse_args "$@"; shift "${names_offset}".
parse_args() {
	[ "$#" -gt 0 ] || {
		usage >&2
		exit 2
	}
	role=''
	mode=''
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
	want=paths
	names_offset=0
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--role | --mode | --skills-dir)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				set_option "$1" "$2"
				shift 2
				names_offset=$((names_offset + 2))
				;;
			--labels)
				want=labels
				shift
				names_offset=$((names_offset + 1))
				;;
			--)
				names_offset=$((names_offset + 1))
				break
				;;
			-*) usage_error "unknown option: $1; expected --role, --mode, --skills-dir, --labels, -- or --help" ;;
			*) break ;;
		esac
	done
	case ${role} in
		developer | reviewer) ;;
		'') usage_error '--role missing; expected --role developer or --role reviewer' ;;
		*) usage_error "--role value '${role}' unknown; expected developer or reviewer" ;;
	esac
	case ${mode} in
		BUILD | TEST) ;;
		'') usage_error '--mode missing; expected --mode BUILD or --mode TEST' ;;
		*) usage_error "--mode value '${mode}' unknown; expected BUILD or TEST" ;;
	esac
}

set_option() {
	case $1 in
		--role) role=$2 ;;
		--mode) mode=$2 ;;
		*) skills_dir=$2 ;;
	esac
}

# Sets listing to list-plugins.sh's plugin lines; exits as the contract says
# when the script is missing, fails, or reports a cut listing. Its exit 1 (no
# plugin installed) is an empty listing.
read_listing() {
	list_script="${skills_dir}/procedure-agent-initialization/scripts/list-plugins.sh"
	[ -f "${list_script}" ] && [ -r "${list_script}" ] ||
		die 4 "list-plugins.sh missing; expected ${list_script}; install the procedure-agent-initialization skill or pass the right --skills-dir"
	stderr_file=$(mktemp "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		die 5 "mktemp could not create a temp file; expected a writable \${TMPDIR:-/tmp}; set TMPDIR to a writable folder"
	if listing=$(sh "${list_script}" --max-lines 0 --skills-dir "${skills_dir}" 2>"${stderr_file}"); then
		list_status=0
	else
		list_status=$?
	fi
	if [ "${list_status}" -eq 1 ]; then
		listing=''
		return 0
	fi
	is_truncated=false
	if awk '/TRUNCATED:/ { found = 1 } END { exit !found }' "${stderr_file}"; then
		is_truncated=true
	fi
	cat "${stderr_file}" >&2
	[ "${list_status}" -ne 0 ] || [ "${is_truncated}" = true ] || return 0
	# A cut listing can't be printed half-right, so it counts as a listing problem
	# (3), as invalid plugins do; every other failure gets 6, apart from this
	# script's own codes.
	case ${list_status} in
		0 | 3) exit 3 ;;
		*) die 6 "list-plugins.sh failed (exit ${list_status}); expected exit 0, 1 or 3; fix what its stderr above names, or reinstall procedure-agent-initialization" ;;
	esac
}

# Sets selected to SELECT_AWK's output for want=$1 and the names after it;
# exits 3 on a name problem.
select_plugins() {
	select_want=$1
	shift
	if selected=$(printf '%s' "${listing}" | awk -v prog="${PROG}" -v mode="${mode}" -v testing="${TESTING_PLUGIN}" -v want="${select_want}" "${SELECT_AWK}" "$@"); then
		return 0
	else
		select_status=$?
	fi
	[ "${select_status}" -eq 3 ] && exit 3
	die 5 "awk failed (exit ${select_status}); expected a POSIX awk; check the awk on PATH"
}

# Sets plugin_value to the selected paths for the role, joined by ", ".
join_paths() {
	plugin_value=''
	while IFS= read -r path; do
		[ -n "${path}" ] || continue
		case ${role}:${path} in
			reviewer:*/references/development.md)
				path="${path%development.md}review.md"
				[ -f "${path}" ] && [ -r "${path}" ] || continue
				add_path "${path}"
				;;
			developer:*/references/development.md)
				add_path "${path}"
				add_templates "${path%development.md}"
				;;
			*) add_path "${path}" ;;
		esac
	done <<EOF
${selected}
EOF
}

# Appends path $1 to plugin_value.
add_path() {
	plugin_value="${plugin_value}${plugin_value:+, }$1"
}

# Appends every readable *-template.md file in the references folder $1 (it
# ends in "/"), in the glob's byte order under the C locale.
add_templates() {
	for template in "$1"*-template.md; do
		[ -f "${template}" ] && [ -r "${template}" ] || continue
		case ${template} in
			*,* | *[[:cntrl:]]*)
				die 3 "template file name holds a comma or control character: ${template}; expected a name the PLUGIN line can carry; rename the file and reinstall the plugin"
				;;
			*) add_path "${template}" ;;
		esac
	done
}

for tool in ${REQUIRED_TOOLS}; do
	command -v "${tool}" >/dev/null 2>&1 ||
		die 5 "${tool} missing; expected it on PATH; install your base system's ${tool}"
done

stderr_file=''
trap remove_stderr_file EXIT
# A signal exits through the EXIT trap, so the temp file goes on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
parse_args "$@"
shift "${names_offset}"
for name in "$@"; do
	[ -n "${name}" ] || usage_error 'empty NAME; expected plugin names such as tech-shell'
done
read_listing
select_plugins paths "$@"
# The paths are joined on --labels too, so their checks and exit codes still apply.
join_paths
if [ "${want}" = paths ]; then
	printf 'PLUGIN: %s\n' "${plugin_value:-none}"
	exit 0
fi
select_plugins labels "$@"
printf '%s\n' "${selected}"
