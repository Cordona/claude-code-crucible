#!/usr/bin/env sh
# Prints the brief's PLUGIN line for the approved plugin names, with the paths
# taken from list-plugins.sh's plugin lines in load order, so the main thread
# never types or orders a path; --labels prints the plugins' LABELS line instead.
# --context-file adds the CONTEXT line, which pins the approved context file by
# its digest so inject-plugins.sh injects only that file; --context-digest
# refuses a file that changed after the plan showed it.
# shellcheck source-path=SCRIPTDIR
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
# <paths...>, so the paths start at field 5. The names are taken out of ARGV,
# each operand split on whitespace, so awk reads stdin.
# The program is single-quoted on purpose: its $ signs are awk's.
# shellcheck disable=SC2016
readonly SELECT_AWK='
function shown(name) { gsub(/[[:cntrl:]]/, "?", name); return name }
function problem(text) { printf "%s: %s\n", prog, text > "/dev/stderr"; failed = 1 }
function add_label(list, label) { return list (list == "" ? "" : ", ") shown(label) }
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
Usage: sh ${PROG} --role developer|reviewer --mode BUILD|TEST [--skills-dir DIR]
           [--context-file CTX [--context-digest HEX] | --labels] [--] [NAME ...]

Prints one line, "PLUGIN: " and the paths of the named plugins joined by ", ",
or "PLUGIN: none" for zero names on --mode BUILD.
With --context-file CTX it prints a second line after it:
  CONTEXT: <CTX> sha256=<64 lowercase hex>
the sha256 of the approved context file, which inject-plugins.sh checks
before it injects the file. CTX must be absolute and hold no control
character, no double quote and no .. segment, must not name a sensitive file
in any letter case (a basename .env*, *.pem, *.key or id_*, or a .git
component), and must be a readable regular file that is not a symlink; these
are inject-plugins.sh's path checks (scripts/lib/context-file.sh). Its content
is not checked here: render-dispatch-plan.sh checked it for the plan and the
hook checks it again. --context-file is not used with --labels.
  HEX  with --context-digest, 12 to 64 lowercase hex digits: the sha256 the
       plan's Context section showed for CTX (its first 12 hex). When CTX's
       sha256 does not start with HEX, it prints nothing on stdout and exits 3
       with "context file: changed since the plan was shown". Only with
       --context-file.
With --labels it prints, instead of the PLUGIN line, one line, "LABELS: " and
the same names' labels (list-plugins.sh's label field, a control character as "?"):
  LABELS: Technology: <tech label, or none> · Used standards: <labels, or none>
the standard labels joined by ", " in the PLUGIN line's order (${TESTING_PLUGIN}
last on --mode TEST). The checks and exit codes are the same as without it.
  NAME  an installed plugin's full name as list-plugins.sh prints it (tech-shell,
        standard-security); a NAME holding whitespace is split into names, in
        order. At most one tech name; no name twice; --mode TEST
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
  3  a name or mode problem, or a context file problem, a changed file
     included (one stderr line each, the context one starting
     "context file:", nothing on stdout),
     invalid plugins reported by list-plugins.sh (its stderr is printed), a
     listing list-plugins.sh reports as TRUNCATED (its stderr is printed), or
     a template name the line can't carry
  4  list-plugins.sh missing
  5  a required tool missing (sha256sum or shasum with --context-file), an awk
     or sha256 tool failure, no temp file could be made, or
     scripts/lib/context-file.sh missing beside this script (--context-file)
  6  list-plugins.sh failed with an exit other than 0, 1 or 3, such as 2
     (skills folder missing or unreadable); its stderr and exit are printed
  129, 130, 143  stopped by HUP, INT or TERM; the temp file is removed

Dependencies: POSIX sh, awk, cat, mktemp, rm; checked at start, a missing one exits 5.
With --context-file also sha256sum or shasum (macOS: shasum -a 256) and
scripts/lib/context-file.sh beside this script.
Runtime: about 79 ms for a tech plugin and 5 standards, measured on macOS (average of 5 runs).
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

# Sets role, mode, skills_dir, want, context_file, shown_digest and the
# positional names from the arguments.
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
	context_file=''
	shown_digest=''
	names_offset=0
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--role | --mode | --skills-dir | --context-file | --context-digest)
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
			-*) usage_error "unknown option: $1; expected --role, --mode, --skills-dir, --context-file, --context-digest, --labels, -- or --help" ;;
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
	[ -z "${context_file}" ] || [ "${want}" = paths ] ||
		usage_error '--context-file is not used with --labels; expected it only when printing the PLUGIN line'
	[ -z "${shown_digest}" ] || check_shown_digest
}

# Refuses a --context-digest without --context-file, or one that is not 12 to
# 64 lowercase hex digits.
check_shown_digest() {
	[ -n "${context_file}" ] ||
		usage_error '--context-digest is used only with --context-file; expected --context-file CTX --context-digest HEX'
	digest_problem="--context-digest value '${shown_digest}' is not 12 to 64 lowercase hex digits; expected the sha256 the plan's Context section shows, such as its 12 hex"
	case ${shown_digest} in
		*[!0-9a-f]*) usage_error "${digest_problem}" ;;
		*) ;;
	esac
	[ "${#shown_digest}" -ge 12 ] && [ "${#shown_digest}" -le 64 ] || usage_error "${digest_problem}"
}

set_option() {
	case $1 in
		--role) role=$2 ;;
		--mode) mode=$2 ;;
		--context-file) context_file=$2 ;;
		--context-digest) shown_digest=$2 ;;
		*) skills_dir=$2 ;;
	esac
}

# Sets context_digest to the sha256 of context_file once its path passes the
# hook's path checks; exits 3 on a path or file problem or a digest that does
# not start with shown_digest, 5 when the shared check or a sha256 tool is
# missing or the tool fails.
digest_context_file() {
	context_lib=$(script_dir)/lib/context-file.sh
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] ||
		die 5 "context path check missing; expected ${context_lib}; reinstall the procedure-agent-initialization skill"
	# shellcheck source=lib/context-file.sh
	. "${context_lib}"
	path_problem=$(context_path_problem "${context_file}")
	[ -z "${path_problem}" ] ||
		die 3 "context file: ${path_problem}: ${context_file}; expected ${context_path_expected}"
	[ ! -L "${context_file}" ] ||
		die 3 "context file: file is a symlink: ${context_file}; expected the regular file the main thread wrote"
	[ -f "${context_file}" ] && [ -r "${context_file}" ] ||
		die 3 "context file: file is missing, unreadable or not a regular file: ${context_file}; expected the readable context file the plan was approved with"
	# shellcheck disable=SC2310 # its status is the lookup result; errexit adds nothing
	find_context_digest_tool ||
		die 5 'sha256sum and shasum missing; expected one of them on PATH; install coreutils (Linux) or use the system shasum (macOS)'
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "${context_file}" ||
		die 5 "${context_digest_tool} could not hash ${context_file}; expected 64 hex digits; check the tool, then rerun"
	case ${context_digest} in
		"${shown_digest}"*) ;;
		*) die 3 "context file: changed since the plan was shown: ${context_file} (sha256 ${shown_digest} shown, ${context_digest} now); expected the file as the plan showed it; show the plan again for the changed file" ;;
	esac
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
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
	case ${name} in
		*[![:space:]]*) ;;
		*) usage_error 'empty NAME; expected plugin names such as tech-shell' ;;
	esac
done
[ -z "${context_file}" ] || digest_context_file
read_listing
select_plugins paths "$@"
# The paths are joined on --labels too, so their checks and exit codes still apply.
join_paths
if [ "${want}" = paths ]; then
	printf 'PLUGIN: %s\n' "${plugin_value:-none}"
	[ -z "${context_file}" ] || printf 'CONTEXT: %s sha256=%s\n' "${context_file}" "${context_digest}"
	exit 0
fi
select_plugins labels "$@"
printf '%s\n' "${selected}"
