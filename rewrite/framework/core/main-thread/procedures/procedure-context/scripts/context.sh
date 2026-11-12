#!/usr/bin/env sh
# Keeps an effort's context: the draft of the next version (its docs folder,
# the pending outside entries, the approved spec and the diff files) in
# drafts/main-thread/context/, and cuts a version from it only when the
# fingerprint a plan pinned still matches. A version is a context.cut event,
# never typed by hand: freeze builds its body from the latest version, the
# docs and the pending entries, checks it as every reader does
# (agent-context-validator.jq and agent-context-file-checks.sh), moves the
# docs to files/context/v<N>/ and appends the event through events.sh, which
# takes the effort's events lock. The main thread runs this script one
# command at a time, so the draft needs no lock of its own.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../engine/crucible/scripts/lib
set -eu
umask 077

readonly PROG='context.sh'
readonly PROCEDURE='procedure-context'
readonly CRUCIBLE_SKILL='crucible'
readonly EFFORT_SKILL='procedure-effort'
readonly NOT_OPEN_EXIT=6
readonly DOCS_EXIT=7
readonly LOCKED_EXIT=8
readonly REQUIRED_TOOLS='cat chmod mkdir mktemp mv rm rmdir tr wc'
readonly ENTRIES_NAME='entries.json'
readonly DRAFT_PATH='drafts/main-thread/context'
readonly FILES_PATH='files/context'
readonly VERSION_EVENT='context.cut'
# The why of each path add --docs-of puts in, before the file name.
readonly DOCS_OF_WHY='documents'
# events.sh's exit when the events lock stayed held past its wait.
readonly EVENTS_LOCKED_EXIT=6
readonly SPEC_APPROVAL_LABEL='spec-approval'
# Room the event's envelope (type, seq, at, by, session) takes around a
# version's body, under the readers' cap.
readonly ENVELOPE_MAX_BYTES=512
# A spec approval counts this long after its answer, as a dispatch plan's does.
readonly APPROVAL_MAX_SECONDS=604800
readonly SPEC_LABEL='spec'
# The tokens a caller matches, never the sentence after them.
readonly NO_SPEC_TOKEN='NO-SPEC'
readonly NO_SPEC_GATE_TOKEN='NO-SPEC-GATE'
readonly CHANGED_TOKEN='CONTEXT-CHANGED'
readonly DOCS_NAME_TOKEN='DOCS-NAME'
readonly DOCS_SIZE_TOKEN='DOCS-SIZE'
readonly NONE_TOKEN='CONTEXT-NONE'
# A problem line shows a value whole up to 80 characters; a longer one keeps
# its first 40 and last 39 around a "…", as a path or URL differs most at its
# start and end.
readonly SHOWN_MAX_CHARS=80
NL='
'
readonly NL
# The C locale keeps the shell's pattern checks and globs byte-wise on macOS
# and Linux.
LC_ALL=C
export LC_ALL

# Prints the pending entries after an add or a drop of one entry, or the
# problem that refuses it, as one JSON object {outcome, entries} or
# {problem}. $entries is next-entries.json ({} when absent), $latest the
# latest version ({} when none); an entry is the same entry when its path or
# URL is. A docs folder is never a pending entry, so it is never matched.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly ENTRY_JQ='
def list: if $kind == "path" then "paths" else "links" end;
def field: if $kind == "path" then "path" else "url" end;
{paths: ($entries.paths // []), links: ($entries.links // []), retire: ($entries.retire // [])} as $e
| [($latest[list] // [])[] | select(has("sha256") | not) | .[field]] as $in_latest
| ($e[list] | map(.[field] == $value) | index(true)) as $pending_at
| ($e.retire | map(.[$kind] == $value) | index(true)) as $retire_at
| if $command == "add" then
	if $retire_at != null then {outcome: "retirement undone", entries: ($e | .retire |= del(.[$retire_at]))}
	elif ($in_latest | index([$value])) != null then {outcome: "already in v\($latest_number)", entries: $e}
	elif $pending_at == null then {outcome: "added", entries: ($e | .[list] += [{(field): $value, why: $why}])}
	elif $e[list][$pending_at].why == $why then {outcome: "already pending", entries: $e}
	else {problem: "is pending already with another why; expected the same --why, or a drop of it first"} end
  elif $pending_at != null then {outcome: "dropped", entries: ($e | .[list] |= del(.[$pending_at]))}
  elif $retire_at != null then {outcome: "retired already", entries: $e}
  elif ($in_latest | index([$value])) != null then {outcome: "retired", entries: ($e | .retire += [{($kind): $value, why: $why}])}
  else {problem: "is neither pending nor in the latest version; expected an entry add put in, or one of the latest version'\''s outside paths and links"} end
| if has("entries") then .entries |= with_entries(select(.value | length > 0)) else . end
'

# Prints one problem line per break of the pending entries read on stdin
# (slurped): one object of paths [{path, why}], links [{url, why}] and retire
# [{path, why} or {link, why}], each list optional; nothing when it fits.
# shellcheck disable=SC2016
readonly ENTRIES_CHECK_JQ='include "agent-context-url";
def one_line: type == "string" and test("[[:cntrl:]]") == false and test("[^[:space:]]");
def entry_ok($field; field_ok): type == "object" and (keys | sort) == ([$field, "why"] | sort) and (.[$field] | field_ok) and (.why | one_line);
def absolute: type == "string" and startswith("/") and test("[[:cntrl:]]") == false;
if length != 1 or (.[0] | type) != "object" then "is not one JSON object"
else .[0]
	| ((keys - ["paths", "links", "retire"])[] | "holds the unknown field \(tojson)"),
	  (if has("paths") and ((.paths | type) != "array" or (.paths | all(entry_ok("path"; absolute)) | not)) then "paths is not an array of {path, why}" else empty end),
	  (if has("links") and ((.links | type) != "array" or (.links | all(entry_ok("url"; http_url)) | not)) then "links is not an array of {url, why}" else empty end),
	  (if has("retire") and ((.retire | type) != "array" or (.retire | all(entry_ok("path"; absolute) or entry_ok("link"; http_url)) | not)) then "retire is not an array of {path, why} or {link, why}" else empty end)
end
'

# Builds the would-be version's body: its number, the latest version's paths
# and links minus the ones pending retirement, then the folder the draft's
# docs move to with their digest when there are any, then the pending paths
# and links not in it yet, then the spec; links left out when there is none.
# shellcheck disable=SC2016
readonly CANDIDATE_JQ='
[($entries.retire // [])[] | {kind: (if has("path") then "path" else "link" end), value: (.path // .link)}] as $gone
| def retired($kind; $value): any($gone[]; .kind == $kind and .value == $value);
(($latest.paths // []) | map(select(has("sha256") or (retired("path"; .path) | not)))) as $kept_paths
| (($latest.links // []) | map(select(retired("link"; .url) | not))) as $kept_links
| ($kept_paths + (if $folder == "" then [] else [{path: $folder, sha256: $digest, why: $folder_why}] end)) as $listed
| ($listed + [($entries.paths // [])[] | select(.path as $path | $listed | any(.path == $path) | not)]) as $paths
| ($kept_links + [($entries.links // [])[] | select(.url as $url | $kept_links | any(.url == $url) | not)]) as $links
| {version: $version, paths: $paths} + (if $links == [] then {} else {links: $links} end) + {spec: $spec}
'

# Shows a value as a JSON string on one line, cut as SHOWN_MAX_CHARS says.
readonly SHOWN_JQ="def shown: tojson | gsub(\"[[:cntrl:]]\"; \"?\") | if length > ${SHOWN_MAX_CHARS} then .[:$((SHOWN_MAX_CHARS / 2))] + \"…\" + .[-$((SHOWN_MAX_CHARS - SHOWN_MAX_CHARS / 2 - 1)):] else . end;"

# The top --help page: every usage line, the commands and what no single
# command owns. Each command's own contract is its `<command> --help` page.
usage() {
	usage_prefix='usage: '
	usage_lines docs add drop spec freeze latest diff
	usage_line "sh ${PROG} <command> --help"
	usage_line "sh ${PROG} --help | -h"
	print_page <<EOF

Keeps an effort's context. The draft of the next version is
<effort>/${DRAFT_PATH}/: its docs folder (docs/) and the pending
outside paths and links (${ENTRIES_NAME}). A version is a ${VERSION_EVENT} event in
<effort>/events/, cut by freeze only while the fingerprint a plan pinned
still matches; its docs move to <effort>/${FILES_PATH}/v<N>/. A version and
the docs it was cut with are never changed by this script.

Commands (each page holds its options, output and exit codes):
  docs    prints the draft's docs folder, creating it
  add     puts an outside path or link into the pending entries
  drop    takes one out, or retires one of the latest version's
  spec    copies an approved spec draft into the folder, or says whether
          the folder holds one
  freeze  prints the fingerprint of the would-be version, or cuts it
  latest  prints the latest version and whether anything is pending
  diff    writes a commit or range of a local repository into the folder
EOF
	help_shared environment
}

# The `<command> --help` page of command $1.
command_help() {
	usage_prefix='usage: '
	usage_lines "$1"
	case $1 in
		docs)
			print_page <<'EOF'

Prints the draft's docs folder, creating it when missing. Nothing else is
left behind.

Options:
EOF
			help_shared effort
			print_page <<'EOF'

stdout on exit 0: DOCS_FOLDER: <the folder, absolute:
  <effort>/drafts/main-thread/context/docs>
EOF
			help_shared exits write
			;;
		add | drop) entry_help "$1" ;;
		spec) spec_help ;;
		freeze) freeze_help ;;
		latest) latest_help ;;
		*) diff_help ;;
	esac
	help_shared environment
	help_shared dependencies "$1"
}

# The add and drop page, command $1.
entry_help() {
	if [ "$1" = add ]; then
		print_page <<EOF

Puts one outside path or link into the draft's ${ENTRIES_NAME}, for the
next cut, or, with --docs-of or --docs-of-file, every file of ROOT naming
FILE or a name in NAMES. The same entry again changes nothing; one pending
retirement is undone instead. The file is replaced whole or not at all.

Options:
EOF
	else
		print_page <<EOF

Takes a pending entry out of the draft's ${ENTRIES_NAME}, or records the
retirement of one of the latest version's outside paths and links, so the
next cut leaves it out. A docs folder is never dropped. The file is
replaced whole or not at all, and removed when it holds nothing.

Options:
EOF
	fi
	help_shared effort
	print_page <<EOF
  --path ABS             an existing readable file or folder (drop: by its
                         text only) outside the effort's
                         ${DRAFT_PATH}/ and ${FILES_PATH}/,
                         not a symlink, nor a path
                         agent-context-file-checks.sh refuses
  --link URL             an http(s) URL; rules: agent-context-url.jq
  --why LINE             one line: why the agent needs it (add), or the
                         human's reason (drop)
  one of --path and --link
EOF
	[ "$1" != add ] || print_page <<EOF
  --docs-of FILE         in place of those three: a file name, no /; each
                         file git grep --untracked -lF finds naming it in
                         ROOT's README* and docs/ is added as a --path, its
                         why "${DOCS_OF_WHY} FILE"; a match --path refuses
                         is left out and named on stderr
  --docs-of-file NAMES   in place of those three: the absolute path of a
                         file of names, one per line, each data, checked
                         and searched as --docs-of FILE; an empty line is
                         skipped, one --docs-of refuses named on stderr
  --repo ROOT            with --docs-of or --docs-of-file: the git
                         work-tree root, absolute
EOF
	print_page <<EOF

stdout on exit 0: ENTRY: <added | already pending | already in v<N> |
  retirement undone | dropped | retired | retired already>
EOF
	if [ "$1" = add ]; then
		print_page <<'EOF'
  --docs-of, --docs-of-file: ADDED: <the path, absolute>, one line per new
  entry; none when nothing is new
EOF
		help_shared exits write '' "  1  a write failed, or git grep did (--docs-of, --docs-of-file), nothing
     of it left; show the human stderr, and stop"
	else
		help_shared exits write
	fi
}

spec_help() {
	print_page <<EOF

--approved copies DRAFT into the draft's docs folder as spec.md,
replacing an earlier one there, once the effort's newest
gate.${SPEC_APPROVAL_LABEL}.answered event approves it, at most 7 days old,
its body.view naming DRAFT at its current sha256. --status reads the docs
folders only.

Options:
EOF
	help_shared effort
	print_page <<EOF
  --approved DRAFT       the draft:
                         <effort>/drafts/main-thread/<ID>-${SPEC_LABEL}.md, a
                         regular file, UTF-8, at most ${docs_cap} bytes
  --status               print whether a docs folder holds a spec
  one of --approved and --status

stdout on exit 0:
  --approved: SPEC_FILE: <the folder's spec.md, absolute>
  --status: SPEC: approved | none; after approved, SPEC_FILE: <the newest
    spec.md, absolute>: the draft's, else the one of the highest v<N>
EOF
	help_shared exits write "     ${NO_SPEC_GATE_TOKEN}  no gate event approves DRAFT as it is now; open
       the spec's approval gate again"
}

freeze_help() {
	print_page <<EOF

--dry-run builds the body of the version a cut would write and prints its
fingerprint, the sha256 of the body as jq -cS . prints it; with no file in
the draft's docs folder and nothing pending, the latest version's. It
writes nothing. --expect cuts it only when its fingerprint is HEX: it
removes a ${FILES_PATH}/v<N>/ no ${VERSION_EVENT} event holds, moves the draft's
docs there with their files read-only (0444), appends the ${VERSION_EVENT}
event of v<N> and removes ${ENTRIES_NAME}. With nothing new, as on a second
call with the same HEX, it returns the latest version. An event is at most
${context_cap} bytes; body shape: agent-context-validator.jq.

Options:
EOF
	help_shared effort
	print_page <<'EOF'
  --dry-run              print the fingerprint
  --expect HEX           cut when the fingerprint is HEX, 64 lowercase hex
                         digits, as --dry-run printed it
  one of --dry-run and --expect

stdout on exit 0:
  --dry-run: FINGERPRINT: <64 lowercase hex digits>
  --expect: CONTEXT_FILE: <the context.cut event, absolute>, then
    CONTEXT_SHA256: <its sha256>
EOF
	help_shared exits write "     ${NO_SPEC_TOKEN}  no docs folder holds a spec.md; approve the spec, then rerun
     ${DOCS_NAME_TOKEN}  a file the docs folder may not hold; rename or remove it
     ${DOCS_SIZE_TOKEN}  the folder's files are over ${docs_cap} bytes; shorten them
     ${CHANGED_TOKEN}  --expect's HEX is not the fingerprint now, a cut docs
       folder changed, or another cut took v<N>; fix what stderr names (a
       new fingerprint: show the plan again)"
}

latest_help() {
	print_page <<'EOF'

Prints the latest version, the newest context.cut event, and the draft's
docs folder when a cut would add something. Reads only.

Options:
EOF
	help_shared effort
	print_page <<EOF

stdout on exits 0 and ${DOCS_EXIT}, in order:
  DOCS_FOLDER: <the draft's docs folder, absolute>  exit ${DOCS_EXIT} only; it
    may not exist yet when only entries are pending
  CONTEXT_FILE: <the latest ${VERSION_EVENT} event, absolute>  when there is one
  CONTEXT_SHA256: <its sha256>  with CONTEXT_FILE
stderr on exit 1: ${PROG}: ${NONE_TOKEN}: ...
EOF
	help_shared exits read '' "  1  ${NONE_TOKEN}: no version, no file in the folder, nothing pending;
     start from discovery" "  ${DOCS_EXIT}  CONTEXT-DOCS: the folder holds files or entries are pending; read
     stdout"
}

diff_help() {
	print_page <<'EOF'

Writes a commit or range of ROOT into the draft's docs folder as
diff-<sha>.patch (a range: diff-<sha>..<sha>.patch), replacing one of the
same name, and leaves out every file --path refuses. ROOT is only read.

Options:
EOF
	help_shared effort
	print_page <<EOF
  --repo ROOT            the git work-tree root, absolute
  --ref REF              a commit or a range A..B of 0-9 A-Z a-z . _ / ^ ~ -
                         only, no part starting with -; its diff non-empty,
                         UTF-8, at most ${docs_cap} bytes

stdout on exit 0: DIFF_FILE: <the patch, absolute>
EOF
	help_shared exits write
}

# Prints the usage lines of each command named, the first after usage_prefix.
usage_lines() {
	for usage_command in "$@"; do
		case ${usage_command} in
			docs) usage_line "sh ${PROG} docs --effort FOLDER" ;;
			add)
				usage_line "sh ${PROG} add --effort FOLDER (--path ABS | --link URL) --why LINE"
				usage_line "sh ${PROG} add --effort FOLDER --docs-of FILE --repo ROOT"
				usage_line "sh ${PROG} add --effort FOLDER --docs-of-file NAMES --repo ROOT"
				;;
			drop) usage_line "sh ${PROG} drop --effort FOLDER (--path ABS | --link URL) --why LINE" ;;
			spec) usage_line "sh ${PROG} spec --effort FOLDER (--approved DRAFT | --status)" ;;
			freeze) usage_line "sh ${PROG} freeze --effort FOLDER (--dry-run | --expect HEX)" ;;
			latest) usage_line "sh ${PROG} latest --effort FOLDER" ;;
			*) usage_line "sh ${PROG} diff --effort FOLDER --repo ROOT --ref REF" ;;
		esac
	done
}

usage_line() {
	printf '%s%s\n' "${usage_prefix}" "$1"
	usage_prefix='       '
}

# The help text more than one page prints, item $1, written once. exits
# takes the command's kind $2 (write or read), the sub-lines under exit 3 $3,
# exit 1's line $4 in place of the write failure's, and exit DOCS_EXIT's $5.
help_shared() {
	case $1 in
		effort)
			print_page <<'EOF'
  --effort FOLDER        the effort folder, as effort.sh start printed it
EOF
			;;
		environment)
			print_page <<'EOF'

Environment:
  CRUCIBLE_HOME          the space (default $HOME/.crucible)
  CLAUDE_CODE_SESSION_ID freeze: required, the session ID Claude Code sets,
                         a lowercase UUID; other commands: not read
  CLAUDE_CONFIG_DIR      the skills are in
                         ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills
EOF
			;;
		exits) help_exits "$2" "${3:-}" "${4:-}" "${5:-}" ;;
		*) help_dependencies "$2" ;;
	esac
}

# Prints a command page's stderr lines and exit codes: kind $1 (write or
# read), the sub-lines under exit 3 $2, exit 1's line $3 and exit
# DOCS_EXIT's $4.
help_exits() {
	print_page <<EOF

stderr on exits 2, 3: one line per problem,
  "${PROG}: <option> <value>: <problem>; expected <x>", or
  "${PROG}: context file: <problem>" for the version as a whole; a refusal
  a caller branches on is "${PROG}: <TOKEN>: <the line>"

Exit codes:
  0  done; read stdout
EOF
	if [ -n "$3" ]; then
		print_page <<EOF
$3
EOF
	elif [ "$1" = write ]; then
		print_page <<'EOF'
  1  a write failed, nothing of it left; show the human stderr, and stop
EOF
	fi
	print_page <<'EOF'
  2  usage error, or CLAUDE_CODE_SESSION_ID bad or naming no session
     transcript; show the human stderr, and stop
  3  refused input, nothing written; fix what stderr names, and rerun
EOF
	[ -z "$2" ] || print_page <<EOF
$2
EOF
	print_page <<EOF
  4  the space is unusable; show the human stderr, and stop
  5  install fault; show the human stderr, and stop
EOF
	[ -z "$4" ] || print_page <<EOF
$4
EOF
	[ "$1" = read ] || print_page <<EOF
  ${NOT_OPEN_EXIT}  the effort is not open or its state unknown, nothing written; show
     the human stderr, and stop
EOF
	[ "${command}" != freeze ] || print_page <<EOF
  ${LOCKED_EXIT}  the effort's events lock stayed held, nothing written; rerun
     once, else show the human stderr (events.sh names the holder)
EOF
	if [ "$1" = write ]; then
		print_page <<'EOF'
  129, 130, 143  stopped by HUP, INT or TERM, nothing of the write left;
     show the human the exit code, and stop
EOF
	else
		print_page <<'EOF'
  129, 130, 143  stopped by HUP, INT or TERM; show the human the exit code,
     and stop
EOF
	fi
}

# Prints the Dependencies lines of command $1.
help_dependencies() {
	print_page <<EOF

Dependencies:
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq);
    ${REQUIRED_TOOLS};
    sha256sum or shasum (macOS: built in)
  the ${CRUCIBLE_SKILL} skill: scripts/lib/crucible-space.sh; events.sh, for
    freeze and spec --approved; ${EFFORT_SKILL}: effort.sh, for a write
  beside this script: agent-context-file-checks.sh, agent-context-validator.jq,
    agent-context-url.jq, context-versions.sh; context-cut-guard.jq, for
    freeze
EOF
	case $1 in
		diff | add)
			print_page <<'EOF'
  git, for diff and add --docs-of or --docs-of-file (macOS: xcode-select
    --install; Linux: the distro's)
EOF
			;;
		*) ;;
	esac
}

# Prints stdin with builtins only, so a page prints with cat missing.
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
	printf "Try '%s%s --help'.\n" "${PROG}" "${command:+ ${command}}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a
# stderr line; tr is checked first, as a usage error can come before the
# tool check.
printable() {
	require_tools
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Sets the caps a page prints, from the shared checks when they load, else
# to where they live.
load_help_values() {
	context_cap='the cap of agent-context-file-checks.sh'
	docs_cap=${context_cap}
	# shellcheck disable=SC2310 # its status says whether the lib was found; errexit adds nothing
	load_context_lib || return 0
	context_cap=${context_max_bytes:-${context_cap}}
	docs_cap=${context_docs_max_bytes:-${docs_cap}}
}

# Removes the temp files and, on a failing exit, a signal included, puts the
# docs a cut moved back into the draft and gives back the read-only mode it
# set: a cut with no event leaves the draft as it found it.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	exit_status=$?
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
	[ -z "${diff_temp}" ] || rm -f "${diff_temp}"
	[ "${exit_status}" -ne 0 ] || return 0
	if [ -n "${moved_folder}" ]; then
		if mv "${moved_folder}" "${next_folder}" 2>/dev/null; then
			warn "moved ${moved_folder} back to ${next_folder}, as no ${VERSION_EVENT} event holds it"
		else
			warn "could not move ${moved_folder} back to ${next_folder}; the next cut removes it, so move it back by hand first"
		fi
	fi
	unlock_files
}

# Gives each file in locked_files its write bit back.
unlock_files() {
	[ -n "${locked_files}" ] || return 0
	while IFS= read -r locked_file; do
		[ -z "${locked_file}" ] || chmod 600 "${locked_file}" 2>/dev/null || true
	done <<EOF
${locked_files}
EOF
	locked_files=''
}

# Sets command and the option values from the arguments; exits 2 on an
# unknown option, a missing value, an option given twice or a missing one.
parse_args() {
	[ "$#" -gt 0 ] || {
		usage >&2
		exit 2
	}
	case $1 in
		--help | -h)
			load_help_values
			usage
			exit 0
			;;
		docs | add | drop | spec | freeze | latest | diff) command=$1 ;;
		*)
			shown_command=$(printable "$1")
			usage_error "unknown command: ${shown_command}; expected docs, add, drop, spec, freeze, latest, diff or --help"
			;;
	esac
	shift
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				load_help_values
				command_help "${command}"
				exit 0
				;;
			--dry-run | --status)
				check_option "$1"
				set_flag "$1"
				shift
				continue
				;;
			*) ;;
		esac
		check_option "$1"
		[ "$#" -ge 2 ] || usage_error "$1 needs a value; expected $1 VALUE"
		[ -n "$2" ] || usage_error "$1 is empty; expected $1 VALUE"
		set_value "$1" "$2"
		shift 2
	done
	require_options
}

# Exits 2 unless option $1 is taken by the command, or when it was given before.
check_option() {
	case ${command}:$1 in
		*:--effort) ;;
		add:--path | add:--link | add:--why | add:--docs-of | add:--docs-of-file | add:--repo | drop:--path | drop:--link | drop:--why) ;;
		spec:--approved | spec:--status | freeze:--dry-run | freeze:--expect | diff:--repo | diff:--ref) ;;
		*)
			shown_option=$(printable "$1")
			expected_options=$(command_options)
			usage_error "unknown option for ${command}: ${shown_option}; expected ${expected_options} or --help"
			;;
	esac
	case " ${seen_options} " in
		*" $1 "*) usage_error "$1 given twice; expected at most one $1" ;;
		*) seen_options="${seen_options} $1" ;;
	esac
}

command_options() {
	case ${command} in
		add) printf '%s' '--effort, --path, --link, --why, --docs-of, --docs-of-file, --repo' ;;
		drop) printf '%s' '--effort, --path, --link, --why' ;;
		spec) printf '%s' '--effort, --approved, --status' ;;
		freeze) printf '%s' '--effort, --dry-run, --expect' ;;
		diff) printf '%s' '--effort, --repo, --ref' ;;
		*) printf '%s' '--effort' ;;
	esac
}

set_flag() {
	case $1 in
		--dry-run) mode=dry-run ;;
		*) mode=status ;;
	esac
}

# Takes value $2 of option $1.
set_value() {
	case $1 in
		--effort) effort_dir=$(without_trailing_slashes "$2") ;;
		--path)
			entry_kind='path'
			entry_value=$(without_trailing_slashes "$2")
			;;
		--link)
			entry_kind='link'
			entry_value=$2
			;;
		--why) entry_why=$2 ;;
		--docs-of) docs_of=$2 ;;
		--docs-of-file) docs_of_file=$2 ;;
		--approved)
			mode=approved
			draft=$2
			;;
		--expect)
			mode=expect
			expected_fingerprint=$2
			;;
		--repo) repo_root=$(without_trailing_slashes "$2") ;;
		*) ref=$2 ;;
	esac
}

# Prints path $1 without trailing slashes ("/" stays "/").
without_trailing_slashes() {
	trimmed=$1
	while [ "${trimmed}" != '/' ] && [ "${trimmed%/}" != "${trimmed}" ]; do
		trimmed=${trimmed%/}
	done
	printf '%s' "${trimmed}"
}

# Exits 2 when an option the command needs is missing, or two that exclude
# each other are given.
require_options() {
	require_option --effort FOLDER
	case ${command} in
		add) require_add_options ;;
		drop) require_entry_options ;;
		spec) require_either --approved --status 'DRAFT' '' ;;
		freeze)
			require_either --dry-run --expect '' 'HEX'
			[ "${mode}" != expect ] || require_fingerprint_option
			;;
		diff)
			require_option --repo ROOT
			require_option --ref REF
			;;
		*) ;;
	esac
}

# add takes an entry's options, or one of --docs-of and --docs-of-file with
# --repo, never two of these forms.
require_add_options() {
	# shellcheck disable=SC2310 # pure tests; their status is the answer
	if ! is_option_seen --docs-of && ! is_option_seen --docs-of-file; then
		require_entry_options
		refuse_option_with --repo '--docs-of FILE or --docs-of-file NAMES'
		return 0
	fi
	require_either --docs-of --docs-of-file 'FILE' 'NAMES'
	for docs_of_excluded in --path --link --why; do
		refuse_option_with "${docs_of_excluded}" '(--path ABS | --link URL) --why LINE'
	done
	require_option --repo ROOT
}

require_entry_options() {
	require_either --path --link 'ABS' 'URL'
	require_option --why LINE
}

# Exits 2 when option $1 was given, as it goes only with options $2.
refuse_option_with() {
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	! is_option_seen "$1" || usage_error "$1 goes only with $2; expected one of the add forms"
}

# Succeeds when option $1 was given.
is_option_seen() {
	case " ${seen_options} " in
		*" $1 "*) return 0 ;;
		*) return 1 ;;
	esac
}

require_option() {
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	is_option_seen "$1" || usage_error "$1 missing; expected $1 $2"
}

# Exits 2 unless exactly one of options $1 and $2 (values $3 and $4) was given.
require_either() {
	either_count=0
	for either_option in "$1" "$2"; do
		case " ${seen_options} " in
			*" ${either_option} "*) either_count=$((either_count + 1)) ;;
			*) ;;
		esac
	done
	[ "${either_count}" -eq 1 ] ||
		usage_error "expected exactly one of $1${3:+ $3} and $2${4:+ $4}"
}

# Exits 2 unless --expect is 64 lowercase hex digits.
require_fingerprint_option() {
	case ${expected_fingerprint} in
		*[!0-9a-f]*) ;;
		*) [ "${#expected_fingerprint}" -ne 64 ] || return 0 ;;
	esac
	usage_error '--expect is not 64 lowercase hex digits; expected the FINGERPRINT freeze --dry-run printed'
}

# Exits 5 naming the first of REQUIRED_TOOLS missing from PATH; checks once.
require_tools() {
	[ -z "${tools_checked}" ] || return 0
	for tool in ${REQUIRED_TOOLS}; do
		command -v "${tool}" >/dev/null 2>&1 ||
			die 5 "${tool} missing; expected it on PATH; install your base system's ${tool}"
	done
	tools_checked=true
}

# Exits 5 unless jq, the shared checks and what they load, and, for a
# write, effort.sh and, for freeze and spec --approved, events.sh are in
# place.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		die 5 'jq missing; expected jq 1.6+ on PATH; install it (macOS: brew install jq; Linux: the distro'\''s jq package)'
	# shellcheck disable=SC2310 # its status says whether the lib was found; errexit adds nothing
	load_context_lib ||
		die 5 "context checks missing; expected ${context_lib}; reinstall the ${PROCEDURE} skill"
	own_scripts_dir=$(script_dir)
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	# shellcheck disable=SC2310 # its status says whether the checks loaded; the problem is read here
	context_load_checks "${skills_dir}" "${own_scripts_dir}" || die 5 "${context_load_problem}"
	case ${command}:${mode} in
		latest: | spec:status | freeze:dry-run) return 0 ;;
		*) ;;
	esac
	events_script="${skills_dir}/${CRUCIBLE_SKILL}/scripts/events.sh"
	case ${command} in
		freeze | spec)
			[ -f "${events_script}" ] && [ -r "${events_script}" ] ||
				die 5 "events.sh missing; expected ${events_script}; install the ${CRUCIBLE_SKILL} skill"
			cut_guard="${own_scripts_dir}/context-cut-guard.jq"
			if [ "${command}" = freeze ] && { [ ! -f "${cut_guard}" ] || [ ! -r "${cut_guard}" ]; }; then
				die 5 "the cut guard missing; expected ${cut_guard}; reinstall the ${PROCEDURE} skill"
			fi
			;;
		*) ;;
	esac
	effort_script="${skills_dir}/${EFFORT_SKILL}/scripts/effort.sh"
	[ -f "${effort_script}" ] && [ -r "${effort_script}" ] ||
		die 5 "effort.sh missing; expected ${effort_script}; install the ${EFFORT_SKILL} skill"
	if [ "${command}" = diff ] || [ -n "${docs_of}${docs_of_file}" ]; then
		command -v git >/dev/null 2>&1 ||
			die 5 "git missing; expected it on PATH; install it (macOS: xcode-select --install; Linux: the distro's git package)"
	fi
}

# Sets context_lib and sources it when it is a readable file; fails otherwise.
load_context_lib() {
	context_lib=$(script_dir)/agent-context-file-checks.sh
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] || return 1
	# shellcheck source=agent-context-file-checks.sh
	. "${context_lib}"
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# freeze: sets session_id from CLAUDE_CODE_SESSION_ID by the space rules, or
# exits 2.
require_session() {
	# shellcheck disable=SC2310 # its status says whether the session is usable; the problem is read here
	crucible_check_session || usage_error "${crucible_session_problem}"
	session_id=${crucible_session_id}
}

# Checks the space and --effort, then sets the effort's context paths;
# exits 4 on a space fault and 3 on a refused --effort.
resolve_effort() {
	# shellcheck disable=SC2310 # its status says whether the root is usable; the problem is read here
	crucible_resolve_root || {
		space_source=''
		[ -n "${CRUCIBLE_HOME:-}" ] ||
			space_source="; CRUCIBLE_HOME is unset or empty, so this is \$HOME/.crucible: fix HOME, or set CRUCIBLE_HOME"
		die 4 "CRUCIBLE_HOME: ${crucible_root_problem}${space_source}"
	}
	# shellcheck disable=SC2310 # its status says whether the folder passed; the problem is read here
	crucible_check_effort_folder "${effort_dir}" || refuse "${crucible_effort_refusal}"
	effort_dir=${crucible_effort}
	context_dir="${effort_dir}/${DRAFT_PATH}"
	next_folder="${context_dir}/docs"
	entries_file="${context_dir}/${ENTRIES_NAME}"
	files_dir="${effort_dir}/${FILES_PATH}"
	events_dir="${effort_dir}/events"
	for layout_dir in "${effort_dir}/drafts" "${context_dir%/*}" "${context_dir}" "${next_folder}" \
		"${files_dir%/*}" "${files_dir}" "${events_dir}"; do
		[ ! -L "${layout_dir}" ] || refuse "--effort ${effort_dir}: ${layout_dir} is a symlink; expected a real folder"
		[ ! -e "${layout_dir}" ] || [ -d "${layout_dir}" ] || refuse "--effort ${effort_dir}: ${layout_dir} is not a folder; expected a real folder"
	done
	[ ! -L "${entries_file}" ] || refuse "--effort ${effort_dir}: ${entries_file} is a symlink; expected the file add and drop write"
}

# Sets latest_path and latest_number (0 when none) to the effort's newest
# context.cut event and its version, and next_number and version_folder to
# the next version's.
read_versions() {
	latest_path='' latest_number=0
	if [ -d "${events_dir}" ]; then
		context_find_latest_version "${events_dir}"
		latest_path=${context_version_latest}
		latest_number=${context_version_latest_number:-0}
	fi
	next_number=$((latest_number + 1))
	version_folder="${files_dir}/v${next_number}"
	[ ! -L "${version_folder}" ] || refuse "--effort ${effort_dir}: ${version_folder} is a symlink; expected a real folder"
}

# Prints problem line $1 and exits 3.
refuse() {
	die 3 "$1"
}

# Exits NOT_OPEN_EXIT unless the effort is open, as effort.sh state, the one
# owner of the state rule, reads it; a state it cannot read refuses too.
require_open_effort() {
	if effort_state_out=$(sh "${effort_script}" state --effort "${effort_dir}" </dev/null); then
		effort_state_status=0
	else
		effort_state_status=$?
	fi
	effort_name=${effort_dir##*/}
	# shellcheck disable=SC2310 # the folder passed the space rules, so its name splits
	crucible_split_id "${effort_name}" && effort_name=${crucible_name_rest}
	case ${effort_state_status} in
		0) ;;
		5) die 5 "effort.sh state names a missing dependency above; expected the ${EFFORT_SKILL} skill working; install what it names, then rerun" ;;
		*) die "${NOT_OPEN_EXIT}" "effort ${effort_name}'s state is unknown (effort.sh state exited ${effort_state_status}; its stderr is above); expected an open effort; ask the human to check the effort" ;;
	esac
	case ${effort_state_out%%"${NL}"*} in
		'STATE: open') ;;
		'STATE: paused' | 'STATE: completed' | 'STATE: dropped')
			effort_state=${effort_state_out%%"${NL}"*}
			die "${NOT_OPEN_EXIT}" "effort ${effort_name} is ${effort_state#STATE: }; expected an open effort; ask the human to reopen it"
			;;
		*) die "${NOT_OPEN_EXIT}" "effort ${effort_name}'s state is unknown (effort.sh state printed no known state); expected an open effort; ask the human to check the effort" ;;
	esac
}

# Creates each of folders $@ that is missing, in order, each in the one
# before it, or exits 1.
make_folders() {
	for needed_dir in "$@"; do
		[ -d "${needed_dir}" ] || mkdir "${needed_dir}" ||
			die 1 "mkdir could not create ${needed_dir}; expected a writable ${needed_dir%/*}; try checking its permissions, then rerun"
	done
}

# Creates the draft's folder, drafts/main-thread/context/, when missing.
ensure_draft() {
	make_folders "${effort_dir}/drafts" "${context_dir%/*}" "${context_dir}"
}

# Creates the draft's docs folder when missing.
ensure_next_folder() {
	ensure_draft
	make_folders "${next_folder}"
}

# Sets temp_file to a new temp file in the draft's folder, the folder every
# write here moves from, so a docs folder never holds a temp file; or exits 1.
make_temp() {
	temp_file=$(mktemp "${context_dir}/.$1.XXXXXX") ||
		die 1 "mktemp could not create a temp file in ${context_dir}; expected a writable folder; try checking its permissions and free space, then rerun"
}

# Moves temp_file onto path $1, replacing it, or exits 1.
commit_temp() {
	mv -f "${temp_file}" "$1" ||
		die 1 "mv could not move the temp file onto $1; expected the file in place; try checking the permissions and free space of ${1%/*}, then rerun"
	temp_file=''
}

# Sets digest to the sha256 of file $1, or exits 5.
file_digest() {
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "$1" ||
		die 5 "${context_digest_tool} could not hash $1; expected its sha256; try ${context_digest_tool} on it, then rerun"
	digest=${context_digest}
}

# docs: prints the draft's docs folder, creating it.
docs_command() {
	require_open_effort
	ensure_next_folder
	printf 'DOCS_FOLDER: %s\n' "${next_folder}"
}

# add and drop: checks the entry, then rewrites the pending entries and
# prints the outcome.
entry_command() {
	entry_problems=$(entry_input_problems)
	if [ -n "${entry_problems}" ]; then
		printf '%s\n' "${entry_problems}" >&2
		exit 3
	fi
	require_open_effort
	read_versions
	load_entries
	check_latest
	apply_entry
	if [ -n "${entry_refusal}" ]; then
		show_entry
		refuse "${entry_option} ${shown_entry}: ${entry_refusal}"
	fi
	write_entries
	printf 'ENTRY: %s\n' "${entry_outcome}"
}

# Runs ENTRY_JQ for the entry on entries_json and sets entry_refusal (empty
# when it passes), and else new_entries and entry_outcome.
apply_entry() {
	# shellcheck disable=SC2016 # the program is jq's
	entry_result=$(jq -c --arg command "${command}" --arg kind "${entry_kind}" --arg value "${entry_value}" \
		--arg why "${entry_why}" --argjson entries "${entries_json}" --argjson latest "${latest_json}" \
		--arg latest_number "${latest_number}" -n "${ENTRY_JQ}" </dev/null) ||
		die 5 'jq failed on the pending entries; expected jq 1.6+; try jq --version, then rerun'
	entry_refusal=$(printf '%s' "${entry_result}" | jq -r '.problem // ""') ||
		die 5 'jq failed reading the outcome; expected jq 1.6+; try jq --version, then rerun'
	[ -z "${entry_refusal}" ] || return 0
	new_entries=$(printf '%s' "${entry_result}" | jq '.entries') ||
		die 5 'jq failed reading the entries; expected jq 1.6+; try jq --version, then rerun'
	entry_outcome=$(printf '%s' "${entry_result}" | jq -r '.outcome') ||
		die 5 'jq failed reading the outcome; expected jq 1.6+; try jq --version, then rerun'
}

# Sets entry_option and shown_entry for a problem line about the entry.
show_entry() {
	entry_option="--${entry_kind}"
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	shown_entry=$(shown_text "${entry_value}") ||
		die 5 'jq failed formatting a value; expected jq 1.6+; try jq --version, then rerun'
}

# Prints value $1 as SHOWN_JQ shows it.
shown_text() {
	# shellcheck disable=SC2016 # the program is jq's
	jq -nr --arg value "$1" "${SHOWN_JQ}"'$value | shown' </dev/null
}

# Prints the problem lines of the entry and its --why, or nothing.
entry_input_problems() {
	show_entry
	case ${entry_why} in
		*[[:cntrl:]]*) printf '%s: --why: holds a control character; expected one line of text\n' "${PROG}" ;;
		*[![:space:]]*) ;;
		*) printf '%s: --why: is blank; expected one line of text\n' "${PROG}" ;;
	esac
	if [ "${entry_kind}" = link ]; then
		# shellcheck disable=SC2016 # the program is jq's
		jq -ne -L "${own_scripts_dir}" --arg url "${entry_value}" 'include "agent-context-url"; $url | http_url' </dev/null >/dev/null 2>&1 ||
			printf '%s: --link %s: is not an http(s) URL; expected the rules of agent-context-url.jq\n' "${PROG}" "${shown_entry}"
		return 0
	fi
	path_problem=$(path_entry_problem "${entry_value}")
	[ -z "${path_problem}" ] || printf '%s: --path %s: %s\n' "${PROG}" "${shown_entry}" "${path_problem}"
}

# Prints the first problem of --path value $1, or nothing. A drop takes a
# path that no longer exists, so it is checked by its text only.
path_entry_problem() {
	shared_problem=$(context_path_problem "$1")
	if [ -n "${shared_problem}" ]; then
		printf '%s; expected %s' "${shared_problem}" "${context_path_expected}"
		return 0
	fi
	case $1/ in
		"${context_dir}"/* | "${files_dir}"/*)
			printf 'is in the effort'\''s %s/ or %s/; expected an outside path: the effort'\''s own docs go into its docs folder' "${DRAFT_PATH}" "${FILES_PATH}"
			return 0
			;;
		*) ;;
	esac
	[ "${command}" = add ] || return 0
	if [ -L "$1" ]; then
		printf 'path is a symlink; expected the real file or folder it points to'
	elif [ -d "$1" ]; then
		[ -r "$1" ] && [ -x "$1" ] || printf 'folder is unreadable; expected a folder the agent can list'
	elif [ -f "$1" ]; then
		[ -r "$1" ] || printf 'file is unreadable; expected a file the agent can read'
	elif [ -e "$1" ]; then
		printf 'path is not a regular file or a folder; expected an existing file or folder'
	else
		printf 'path does not exist; expected an existing file or folder'
	fi
}

# add --docs-of and --docs-of-file: finds the files of ROOT's README* and
# docs/ that name each file name, then puts each into the pending entries
# through the checks --path takes, and prints an ADDED line per
# new one. A match those checks refuse, or one pending with another why, is
# named on stderr and left out.
docs_of_command() {
	if [ -n "${docs_of_file}" ]; then
		docs_of_option=--docs-of-file
		read_docs_names_file
	else
		docs_of_option=--docs-of
		take_docs_of_name
	fi
	repo_problem=$(repo_root_problem)
	[ -z "${repo_problem}" ] || refuse "--repo ${repo_root}: ${repo_problem}"
	require_open_effort
	find_all_documenting_files
	[ -n "${documenting_pairs}" ] || return 0
	read_versions
	load_entries
	check_latest
	entry_kind=path added_lines='' is_entries_changed=false
	while IFS= read -r documenting_pair; do
		[ -n "${documenting_pair}" ] || continue
		docs_of=${documenting_pair%%/*}
		entry_why="${DOCS_OF_WHY} ${docs_of}"
		add_documenting_file "${repo_root}/${documenting_pair#*/}"
	done <<EOF
${documenting_pairs}
EOF
	[ "${is_entries_changed}" = false ] || {
		new_entries=${entries_json}
		write_entries
	}
	[ -z "${added_lines}" ] || printf '%s' "${added_lines}"
}

# Sets docs_names to --docs-of, or exits 3 when docs_name_problem refuses it.
take_docs_of_name() {
	docs_of_problem=$(docs_name_problem "${docs_of}")
	if [ -n "${docs_of_problem}" ]; then
		show_value "${docs_of}"
		refuse "--docs-of ${shown_value}: ${docs_of_problem}"
	fi
	docs_names=${docs_of}
}

# Sets docs_names to the lines of --docs-of-file that docs_name_problem
# passes, one per line and each once, read as data only: an empty line is
# skipped, a refused one named on stderr with its line number and skipped.
# Exits 3 when the file is not an absolute path of a readable regular file.
read_docs_names_file() {
	case ${docs_of_file} in
		/*) docs_file_problem='' ;;
		*) docs_file_problem='is not an absolute path' ;;
	esac
	if [ -z "${docs_file_problem}" ] &&
		{ [ -L "${docs_of_file}" ] || [ ! -f "${docs_of_file}" ] || [ ! -r "${docs_of_file}" ]; }; then
		docs_file_problem='is missing, unreadable, a symlink or not a regular file'
	fi
	if [ -n "${docs_file_problem}" ]; then
		show_value "${docs_of_file}"
		refuse "--docs-of-file ${shown_value}: ${docs_file_problem}; expected the absolute path of a file of names, one per line"
	fi
	docs_names='' docs_names_line=0
	while IFS= read -r docs_name || [ -n "${docs_name}" ]; do
		docs_names_line=$((docs_names_line + 1))
		[ -n "${docs_name}" ] || continue
		docs_of_problem=$(docs_name_problem "${docs_name}")
		if [ -n "${docs_of_problem}" ]; then
			show_value "${docs_name}"
			warn "--docs-of-file line ${docs_names_line} ${shown_value}: ${docs_of_problem}; left out"
			continue
		fi
		case ${NL}${docs_names} in
			*"${NL}${docs_name}${NL}"*) ;;
			*) docs_names="${docs_names}${docs_name}${NL}" ;;
		esac
	done <"${docs_of_file}"
}

# Sets shown_value to value $1 as SHOWN_JQ shows it, or exits 5.
show_value() {
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	shown_value=$(shown_text "$1") ||
		die 5 'jq failed formatting a value; expected jq 1.6+; try jq --version, then rerun'
}

# Prints the problem of file name $1, as --docs-of and --docs-of-file take
# it, or nothing when it is a file name.
docs_name_problem() {
	case $1 in
		*[[:cntrl:]]*) printf 'holds a control character; expected a file name on one line' ;;
		*/*) printf 'holds a /; expected a file name alone, such as auth.sh' ;;
		*) ;;
	esac
}

# Sets documenting_pairs to one "<name>/<match>" line per file of ROOT's
# README* and docs/ naming a name of docs_names, <match> relative to ROOT;
# a name holds no /, so a line splits at its first one.
find_all_documenting_files() {
	documenting_pairs=''
	while IFS= read -r docs_of; do
		[ -n "${docs_of}" ] || continue
		find_documenting_files
		while IFS= read -r docs_of_match; do
			[ -z "${docs_of_match}" ] || documenting_pairs="${documenting_pairs}${docs_of}/${docs_of_match}${NL}"
		done <<EOF
${docs_of_matches}
EOF
	done <<EOF
${docs_names}
EOF
}

# Sets docs_of_matches to the paths, relative to ROOT and one per line, of
# the files in ROOT's README* and docs/, untracked ones included, whose text
# holds file name docs_of; empty on no match (git grep's exit 1), or exits 1.
# core.quotePath=false prints a UTF-8 name as it is; a name git still quotes
# keeps its double quotes, which the --path checks refuse.
find_documenting_files() {
	# shellcheck disable=SC2310 # its status is git's; it is read below
	if docs_of_matches=$(run_git -c core.quotePath=false grep --untracked -lF -e "${docs_of}" -- 'README*' 'docs/'); then
		return 0
	else
		grep_status=$?
	fi
	docs_of_matches=''
	[ "${grep_status}" -eq 1 ] ||
		die 1 "git grep failed in ${repo_root} (exit ${grep_status}); its stderr is above; expected the files that name ${docs_of}; try the fix git names, then rerun"
}

# Puts path $1 into entries_json as add --path would, through the same
# checks, and adds its ADDED line to added_lines when it is new.
add_documenting_file() {
	entry_value=$1
	show_entry
	path_problem=$(path_entry_problem "$1")
	if [ -n "${path_problem}" ]; then
		warn "${docs_of_option} ${docs_of}: left out ${shown_entry}: ${path_problem}"
		return 0
	fi
	apply_entry
	if [ -n "${entry_refusal}" ]; then
		warn "${docs_of_option} ${docs_of}: left out ${shown_entry}: ${entry_refusal}"
		return 0
	fi
	case ${entry_outcome} in
		added) added_lines="${added_lines}ADDED: $1${NL}" ;;
		'retirement undone') ;;
		*) return 0 ;;
	esac
	entries_json=${new_entries}
	is_entries_changed=true
}

# Sets entries_json to the pending entries ({} when none), or exits 3 when
# the file is not as add and drop write it.
load_entries() {
	entries_json='{}'
	[ -e "${entries_file}" ] || return 0
	[ -f "${entries_file}" ] && [ -r "${entries_file}" ] ||
		refuse "--effort ${effort_dir}: ${entries_file} is not a readable regular file; expected the file add and drop write"
	entries_problems=$(jq -rs -L "${own_scripts_dir}" "${ENTRIES_CHECK_JQ}" "${entries_file}" </dev/null 2>/dev/null) ||
		refuse "--effort ${effort_dir}: ${entries_file} is not valid JSON; expected the file add and drop write; ask the human, as only add and drop write it"
	[ -n "${entries_problems}" ] || {
		entries_json=$(jq -c . "${entries_file}") ||
			die 5 'jq failed reading the pending entries; expected jq 1.6+; try jq --version, then rerun'
		return 0
	}
	joined_problems=$(join_lines "${entries_problems}")
	refuse "--effort ${effort_dir}: ${entries_file} ${joined_problems}; expected the file add and drop write; ask the human, as only add and drop write it"
}

# Writes new_entries over the pending entries, or removes the file when they
# hold nothing.
write_entries() {
	if [ "${new_entries}" = '{}' ]; then
		rm -f "${entries_file}" ||
			die 1 "rm could not remove ${entries_file}; expected it gone; try checking the permissions of ${context_dir}, then rerun"
		return 0
	fi
	ensure_draft
	make_temp "${ENTRIES_NAME}"
	printf '%s\n' "${new_entries}" >"${temp_file}" ||
		die 1 "could not write the temp file ${temp_file}; expected the entries written; try checking free space, then rerun"
	commit_temp "${entries_file}"
}

# Prints the lines of $1 joined by "; ".
join_lines() {
	joined=''
	while IFS= read -r line; do
		joined="${joined}${joined:+; }${line}"
	done <<EOF
$1
EOF
	printf '%s' "${joined}"
}

# spec: --status or --approved.
spec_command() {
	if [ "${mode}" = status ]; then
		print_spec_status
		return 0
	fi
	draft_problem=$(draft_path_problem)
	[ -z "${draft_problem}" ] || refuse "--approved ${draft}: ${draft_problem}"
	file_digest "${draft}"
	approved_digest=${digest}
	# shellcheck disable=SC2310 # its status says whether the event approves the draft
	spec_approval_matches "${draft}" "${approved_digest}" ||
		refuse "${NO_SPEC_GATE_TOKEN}: --approved ${draft}: the newest gate.${SPEC_APPROVAL_LABEL}.answered event does not approve this draft as it is now, or is over 7 days old; expected the spec approved at its gate"
	require_open_effort
	ensure_next_folder
	make_temp spec.md
	cat "${draft}" >"${temp_file}" ||
		die 1 "could not copy ${draft} into the temp file ${temp_file}; expected the copy written; try checking free space, then rerun"
	file_digest "${temp_file}"
	[ "${digest}" = "${approved_digest}" ] ||
		refuse "--approved ${draft}: changed while it was copied; expected the draft as its gate approved it; approve the draft as it is now at its gate"
	commit_temp "${next_folder}/spec.md"
	printf 'SPEC_FILE: %s\n' "${next_folder}/spec.md"
}

# spec --status: prints whether a docs folder holds a spec.md and, when one
# does, the newest: the draft's, else the one in the folder of the highest
# version a context.cut event holds.
print_spec_status() {
	newest_spec='' newest_number=0
	read_versions
	if [ -f "${next_folder}/spec.md" ] && [ ! -L "${next_folder}/spec.md" ]; then
		newest_spec="${next_folder}/spec.md"
	elif [ -d "${files_dir}" ]; then
		for spec_candidate in "${files_dir}"/v*/spec.md; do
			[ -f "${spec_candidate}" ] && [ ! -L "${spec_candidate}" ] || continue
			spec_folder=${spec_candidate%/spec.md}
			spec_number=${spec_folder##*/v}
			case ${spec_number} in
				'' | 0* | *[!0-9]*) continue ;;
				*) ;;
			esac
			[ "${#spec_number}" -le "${context_version_max_digits}" ] || continue
			[ "${spec_number}" -gt "${newest_number}" ] && [ "${spec_number}" -le "${latest_number}" ] || continue
			newest_spec=${spec_candidate} newest_number=${spec_number}
		done
	fi
	if [ -z "${newest_spec}" ]; then
		printf 'SPEC: none\n'
		return 0
	fi
	printf 'SPEC: approved\nSPEC_FILE: %s\n' "${newest_spec}"
}

# Prints the problem of the --approved draft, or nothing: a path --path
# takes, named as a spec draft of this effort, a readable regular file,
# UTF-8 and under the cap.
draft_path_problem() {
	shared_problem=$(context_path_problem "${draft}")
	if [ -n "${shared_problem}" ]; then
		printf '%s; expected %s' "${shared_problem}" "${context_path_expected}"
		return 0
	fi
	draft_dir=${draft%/*}
	# shellcheck disable=SC2310 # pure tests; their status is the answer
	if ! crucible_split_id "${draft##*/}" || [ "${crucible_name_rest}" != "${SPEC_LABEL}.md" ] ||
		[ "${draft_dir}" != "${effort_dir}/drafts/main-thread" ]; then
		printf 'is not a spec draft of this effort; expected %s/drafts/main-thread/<ID>-%s.md' "${effort_dir}" "${SPEC_LABEL}"
		return 0
	fi
	if [ -L "${draft}" ] || [ ! -f "${draft}" ] || [ ! -r "${draft}" ]; then
		printf 'is missing, unreadable, a symlink or not a regular file; expected the draft the approval gate showed'
		return 0
	fi
	# shellcheck disable=SC2310 # it prints the problem; its status only says whether there was one
	long_text_problem "${draft}" 'the draft' || true
}

# Prints the problem of text file $1, the agent's $2, against the docs cap
# and UTF-8, and succeeds; fails, printing nothing, when it fits.
long_text_problem() {
	text_bytes=$(wc -c <"$1") ||
		die 5 "wc could not count the bytes of $1; expected a byte count; try wc -c on it, then rerun"
	text_bytes=${text_bytes##* }
	if [ "${text_bytes}" -gt "${context_docs_max_bytes}" ]; then
		printf '%s is %s bytes; expected at most %s bytes' "$2" "${text_bytes}" "${context_docs_max_bytes}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the check result; errexit adds nothing
	text_is_utf8 "$1" && return 1
	printf '%s is not valid UTF-8; expected %s as UTF-8' "$2" "$2"
}

# Succeeds when file $1 reads back unchanged through jq --rawfile, which turns
# invalid UTF-8 into U+FFFD, so its bytes are valid UTF-8.
text_is_utf8() {
	# shellcheck disable=SC2310 # the caller reports a failure; errexit adds nothing
	compute_context_digest "$1" || return 1
	utf8_file_digest=${context_digest}
	# shellcheck disable=SC2016,SC2310 # $text is jq's; the caller reports a failure
	utf8_text_digest=$(jq -nj --rawfile text "$1" '$text' </dev/null | context_print_stdin_digest) || return 1
	[ "${utf8_file_digest}" = "${utf8_text_digest}" ]
}

# Succeeds when the effort's newest gate.spec-approval.answered event
# approves draft $1 at sha256 $2: body.approved true, its at at most
# APPROVAL_MAX_SECONDS ago, and body.view the approval plan
# render-spec-gate.sh --approval-plan wrote for that draft. An event jq cannot
# read so matches nothing. events.sh's space fault (exit 4) stays this
# script's space exit; any other failure is an install fault.
spec_approval_matches() {
	if approval_event=$(sh "${events_script}" latest --effort "${effort_dir}" --type "gate.${SPEC_APPROVAL_LABEL}.answered" </dev/null); then
		latest_status=0
	else
		latest_status=$?
	fi
	case ${latest_status} in
		0) ;;
		4) die 4 "events.sh latest could not read the effort's events; its stderr is above; expected a readable ${events_dir}; fix what it names, then rerun" ;;
		*) die 5 "events.sh latest failed on the effort's events (exit ${latest_status}); its stderr is above; fix what it names, then rerun" ;;
	esac
	[ -n "${approval_event}" ] || return 1
	# shellcheck disable=SC2016 # the program is jq's
	jq -e --arg spec "$1" --arg sha256 "$2" --argjson max_age "${APPROVAL_MAX_SECONDS}" \
		'.body.approved == true and (.body.view | type) == "object" and .body.view.case == "approval"
		and .body.view.spec == $spec and .body.view.sha256 == $sha256
		and (now - (.at | fromdateiso8601)) <= $max_age' "${approval_event}" </dev/null >/dev/null 2>&1
}

# freeze: --dry-run prints the fingerprint; --expect cuts the version when it
# matches.
freeze_command() {
	require_session
	if [ "${mode}" = dry-run ]; then
		read_versions
		build_candidate
		printf 'FINGERPRINT: %s\n' "${fingerprint}"
		return 0
	fi
	require_open_effort
	read_versions
	build_candidate
	[ "${fingerprint}" = "${expected_fingerprint}" ] ||
		refuse "${CHANGED_TOKEN}: --expect ${expected_fingerprint}: the context's fingerprint is ${fingerprint} now; expected the inputs as the plan pinned them; take a fresh fingerprint with freeze --dry-run and show the plan again"
	if [ "${is_nothing_new}" = true ]; then
		print_version "${latest_path}"
		return 0
	fi
	cut_version
}

# Exits 3 with the NO-SPEC refusal.
refuse_no_spec() {
	refuse "${NO_SPEC_TOKEN}: --effort ${effort_dir}: no docs folder up to v${next_number:-1} holds a spec.md; expected an approved spec (${PROG} spec --approved) before a cut"
}

# Sets is_nothing_new and fingerprint, and, when something is new,
# candidate_json, the would-be version; exits 3 on every refusal of the cut.
build_candidate() {
	check_latest
	scan_next_folder
	load_entries
	is_nothing_new=false
	if [ "${next_count}" -eq 0 ] && [ ! -e "${entries_file}" ]; then
		[ -n "${latest_path}" ] || refuse_no_spec
		is_nothing_new=true
		# shellcheck disable=SC2310 # its status is a tool's; a failure exits
		fingerprint_of "${latest_json}" || die 5 'jq or the sha256 tool failed on the latest version; expected jq 1.6+; try jq --version, then rerun'
		return 0
	fi
	folder_entry='' candidate_spec=''
	if [ "${next_count}" -gt 0 ]; then
		folder_entry=${version_folder}
		[ ! -f "${next_folder}/spec.md" ] || candidate_spec="${version_folder}/spec.md"
	fi
	if [ -z "${candidate_spec}" ] && [ -n "${latest_path}" ]; then
		candidate_spec=$(jq -r '.body.spec // ""' "${latest_path}" </dev/null) ||
			die 5 'jq failed reading the latest version; expected jq 1.6+; try jq --version, then rerun'
	fi
	[ -n "${candidate_spec}" ] || refuse_no_spec
	# shellcheck disable=SC2016 # the program is jq's
	candidate_json=$(jq -n --argjson latest "${latest_json}" --argjson entries "${entries_json}" \
		--arg folder "${folder_entry}" --arg digest "${next_digest}" --arg folder_why "the effort's docs for v${next_number}" \
		--arg spec "${candidate_spec}" --argjson version "${next_number}" "${CANDIDATE_JQ}" </dev/null) ||
		die 5 'jq failed building the version; expected jq 1.6+; try jq --version, then rerun'
	check_candidate
	# shellcheck disable=SC2310 # its status is a tool's; a failure exits
	fingerprint_of "${candidate_json}" || die 5 'jq or the sha256 tool failed on the would-be version; expected jq 1.6+; try jq --version, then rerun'
}

# Sets latest_json to the latest version, its event's body ({} when none),
# or exits 3 when it fails the read checks: a cut docs folder changed leads
# with CONTEXT-CHANGED.
check_latest() {
	latest_json='{}'
	[ -n "${latest_path}" ] || return 0
	# shellcheck disable=SC2310 # its status is a tool's; a failure has printed its cause
	context_read_problem "${latest_path}" ||
		die 5 'a tool failed reading the latest version (its stderr is above); expected jq 1.6+ and wc; try jq --version, then rerun'
	latest_shown="--effort ${effort_dir}: its latest version v${latest_number} (${latest_path})"
	case ${context_read_fault} in
		'') ;;
		changed) refuse "${CHANGED_TOKEN}: ${latest_shown}: ${context_read_text#"${CHANGED_TOKEN}: "}" ;;
		no-spec) refuse "${NO_SPEC_TOKEN}: ${latest_shown}: ${context_read_text#"${NO_SPEC_TOKEN}: "}" ;;
		*) refuse "${latest_shown}: ${context_read_text}" ;;
	esac
	latest_json=$(jq -c .body "${latest_path}") ||
		die 5 'jq failed reading the latest version; expected jq 1.6+; try jq --version, then rerun'
}

# Sets next_count and next_digest for the draft's docs folder (0 and empty
# when it holds no file), or exits 3 on a file it may not hold (DOCS-NAME) or
# its files over the cap (DOCS-SIZE).
scan_next_folder() {
	next_count=0 next_digest=''
	[ -d "${next_folder}" ] || return 0
	# shellcheck disable=SC2310 # its status is a tool's; a failure exits
	context_docs_scan "${next_folder}" ||
		die 5 "a tool failed hashing ${next_folder} (its stderr is above); expected sha256sum or shasum, cat and wc; rerun"
	[ -z "${context_docs_problem}" ] ||
		refuse "${DOCS_NAME_TOKEN}: --effort ${effort_dir}: ${next_folder}/${context_docs_problem#"${DOCS_NAME_TOKEN}: "}"
	[ "${context_docs_bytes}" -le "${context_docs_max_bytes}" ] ||
		refuse "${DOCS_SIZE_TOKEN}: --effort ${effort_dir}: ${next_folder}: its files are ${context_docs_bytes} bytes; expected at most ${context_docs_max_bytes} bytes: short notes naming their sources"
	next_count=${context_docs_count}
	next_digest=${context_docs_digest}
}

# Exits 3 on what the validator, for this effort, and the size cap find in
# candidate_json. The cap leaves ENVELOPE_MAX_BYTES for the event around it,
# so the event a cut appends passes the readers' cap too.
check_candidate() {
	candidate_problems=$(printf '%s\n' "${candidate_json}" | jq -rs --arg effort "${effort_dir}" -f "${context_validator}") ||
		die 5 'jq failed on the context validator; expected jq 1.6+; try jq --version, then rerun'
	candidate_bytes=$(printf '%s\n' "${candidate_json}" | wc -c) ||
		die 5 'wc could not count the version bytes; expected a byte count; rerun'
	candidate_bytes=${candidate_bytes##* }
	body_max_bytes=$((context_max_bytes - ENVELOPE_MAX_BYTES))
	[ "${candidate_bytes}" -le "${body_max_bytes}" ] ||
		candidate_problems="${candidate_problems}${candidate_problems:+${NL}}the would-be version is ${candidate_bytes} bytes; expected at most ${body_max_bytes} bytes: fewer outside entries"
	[ -n "${candidate_problems}" ] || return 0
	while IFS= read -r candidate_problem; do
		warn "context file: ${candidate_problem}"
	done <<EOF
${candidate_problems}
EOF
	exit 3
}

# Sets fingerprint to the sha256 of version JSON $1 as jq -cS . prints it.
fingerprint_of() {
	normalized=$(printf '%s\n' "$1" | jq -cS .) || return 1
	# shellcheck disable=SC2310 # the caller reports a failure
	fingerprint=$(printf '%s\n' "${normalized}" | context_print_stdin_digest) || return 1
}

# Moves the draft's docs, their files made read-only, to version_folder,
# appends candidate_json as the context.cut event of v<next_number>, checks
# it as a reader does, removes the pending entries and prints it. A failing
# exit before the event is written moves the docs back (clean_up).
cut_version() {
	remove_leftover_folder
	if [ "${next_count}" -gt 0 ]; then
		make_folders "${effort_dir}/files" "${files_dir}"
		lock_folder_files
		mv "${next_folder}" "${version_folder}" ||
			die 1 "mv could not move ${next_folder} to ${version_folder}; expected the docs moved; try checking the permissions of ${files_dir}, then rerun"
		moved_folder=${version_folder}
		check_moved_folder
	fi
	make_temp "${VERSION_EVENT}"
	printf '%s\n' "${candidate_json}" >"${temp_file}" ||
		die 1 "could not write the temp file ${temp_file}; expected the version written; try checking free space, then rerun"
	append_version_event
	moved_folder='' locked_files=''
	rm -f "${temp_file}"
	temp_file=''
	# shellcheck disable=SC2310 # its status is a tool's; a failure has printed its cause
	context_read_problem "${version_event}" ||
		die 5 'a tool failed reading the written version (its stderr is above); expected jq 1.6+ and wc; try jq --version, then rerun'
	[ -z "${context_read_fault}" ] ||
		die 1 "the ${VERSION_EVENT} event ${version_event} is written but fails the read checks: ${context_read_text}; expected a version that passes; show the human stderr, and reinstall the ${PROCEDURE} skill"
	rm -f "${entries_file}" ||
		die 1 "rm could not remove ${entries_file}; expected the entries cut into the version gone; try checking the permissions of ${context_dir}, then rerun"
	[ "${next_count}" -gt 0 ] || [ ! -d "${next_folder}" ] || rmdir "${next_folder}" 2>/dev/null || true
	print_version "${version_event}"
}

# Removes version_folder when it is there: no context.cut event holds
# v<next_number> yet, so it is what a cut that stopped between its move and
# its append left behind.
remove_leftover_folder() {
	[ -e "${version_folder}" ] || return 0
	[ -d "${version_folder}" ] ||
		refuse "--effort ${effort_dir}: ${version_folder} is not a folder; expected nothing there before the cut of v${next_number}"
	warn "removing ${version_folder}: no ${VERSION_EVENT} event holds it, so a cut left it before its event"
	rm -rf "${version_folder}" ||
		die 1 "rm could not remove ${version_folder}; expected it gone before the cut; try checking the permissions of ${files_dir}, then rerun"
}

# Exits 1 unless version_folder still gives the digest the draft's docs gave.
check_moved_folder() {
	# shellcheck disable=SC2310 # its status is a tool's; a failure exits
	context_docs_scan "${version_folder}" ||
		die 5 "a tool failed hashing ${version_folder} (its stderr is above); expected sha256sum or shasum, cat and wc; rerun"
	[ "${context_docs_digest}" = "${next_digest}" ] ||
		die 1 "${version_folder} gives another digest after the move; expected the docs as scanned; rerun"
}

# Appends the version in temp_file through events.sh, whose guard refuses it
# when another cut took v<next_number> first; sets version_event.
append_version_event() {
	if version_event=$(sh "${events_script}" append --effort "${effort_dir}" --type "${VERSION_EVENT}" --by "${PROG}" \
		--body-file "${temp_file}" --session "${session_id}" --guard "${cut_guard}" </dev/null); then
		append_status=0
	else
		append_status=$?
	fi
	case ${append_status} in
		0) ;;
		3) refuse "${CHANGED_TOKEN}: --effort ${effort_dir}: events.sh refused the ${VERSION_EVENT} event of v${next_number} (its stderr is above); expected v${next_number} free and the effort open; take a fresh fingerprint with freeze --dry-run and show the plan again" ;;
		"${EVENTS_LOCKED_EXIT}") die "${LOCKED_EXIT}" "--effort ${effort_dir}: the events lock stayed held (events.sh stderr above names its holder); expected one writer at a time; rerun once the other call has ended" ;;
		4) die 4 "events.sh could not write the ${VERSION_EVENT} event (its stderr is above); expected a writable ${events_dir}; fix what it names, then rerun" ;;
		*) die 5 "events.sh exited ${append_status} (its stderr is above); expected exit 0; try reinstalling the ${CRUCIBLE_SKILL} skill" ;;
	esac
}

# Makes every file of the draft's docs folder read-only, recording each in
# locked_files so a failing exit gives the write bit back.
lock_folder_files() {
	[ "${next_count}" -gt 0 ] || return 0
	for folder_file in "${next_folder}"/*; do
		[ -f "${folder_file}" ] || continue
		chmod 444 "${folder_file}" ||
			die 1 "chmod could not make ${folder_file} read-only; expected mode 0444; try checking its owner, then rerun"
		locked_files="${locked_files}${folder_file}${NL}"
	done
}

# Prints context.cut event $1's path and sha256.
print_version() {
	file_digest "$1"
	printf 'CONTEXT_FILE: %s\nCONTEXT_SHA256: %s\n' "$1" "${digest}"
}

# latest: prints the latest version and, when a cut would add something, the
# draft's docs folder (exit DOCS_EXIT); exits 1 with nothing at all. A name
# starting with . counts for nothing, as context_docs_scan skips it.
latest_command() {
	read_versions
	check_latest
	is_pending=false
	[ ! -e "${entries_file}" ] || is_pending=true
	if [ -d "${next_folder}" ]; then
		for next_entry in "${next_folder}"/*; do
			[ -e "${next_entry}" ] || [ -L "${next_entry}" ] || continue
			is_pending=true
			break
		done
	fi
	if [ "${is_pending}" = false ] && [ -z "${latest_path}" ]; then
		die 1 "${NONE_TOKEN}: --effort ${effort_dir}: no context version, no file in ${next_folder} and nothing pending yet"
	fi
	[ "${is_pending}" = false ] || printf 'DOCS_FOLDER: %s\n' "${next_folder}"
	[ -z "${latest_path}" ] || print_version "${latest_path}"
	[ "${is_pending}" = false ] || exit "${DOCS_EXIT}"
}

# Runs git read-only in repo_root with the arguments given. Pathspec magic
# stays on whatever the caller's environment says, so the excludes below hold.
run_git() {
	GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 GIT_LITERAL_PATHSPECS=0 \
		git --no-pager -c core.fsmonitor=false -C "${repo_root}" "$@" </dev/null
}

# Runs git as run_git does, leaving out every file context_path_problem
# refuses as sensitive or as a Claude settings file, so a diff can't carry
# what --path may not.
git_without_sensitive_files() {
	# shellcheck disable=SC2310 # its status is the lib's; a failure fails the git run
	excluded_pathspecs=$(context_excluded_pathspecs) || return 1
	set -- "$@" -- .
	while IFS= read -r excluded_pathspec; do
		[ -z "${excluded_pathspec}" ] || set -- "$@" "${excluded_pathspec}"
	done <<EOF
${excluded_pathspecs}
EOF
	find_config_settings_exclude
	[ -z "${config_settings_exclude}" ] || set -- "$@" "${config_settings_exclude}"
	run_git "$@"
}

# Sets config_settings_exclude to the pathspec leaving out the Claude config
# dir's settings.json when that dir is repo_root or, as text, a folder under
# it, the way context_config_path_problem compares it; to empty otherwise.
# literal keeps a * or [ in a folder name from matching other paths.
find_config_settings_exclude() {
	config_settings_exclude=''
	config_dir=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}
	while [ "${config_dir}" != "${config_dir%/}" ]; do
		config_dir=${config_dir%/}
	done
	config_folder=${config_dir}/
	case ${config_folder} in
		"${repo_root}"/*)
			config_settings_exclude=":(exclude,icase,literal)${config_folder#"${repo_root}"/}settings.json"
			;;
		*) ;;
	esac
}

# Prints the problem of --repo, or nothing when it is an absolute, existing
# git work-tree root.
repo_root_problem() {
	case ${repo_root} in
		/*) ;;
		*)
			printf 'not an absolute path; expected the repository'\''s git work-tree root'
			return 0
			;;
	esac
	if [ ! -d "${repo_root}" ]; then
		printf 'not an existing folder; expected the repository'\''s git work-tree root'
		return 0
	fi
	# shellcheck disable=SC2310 # its status is git's answer; a failure is reported
	if ! git_root=$(run_git rev-parse --show-toplevel 2>/dev/null); then
		printf 'not in a git work tree; expected the repository'\''s git work-tree root'
		return 0
	fi
	[ "${git_root}" = "${repo_root}" ] || printf 'not the git work-tree root; expected %s' "${git_root}"
}

# Prints why --ref breaks its rule, or nothing.
ref_syntax_problem() {
	ref_rule='a commit or a range A..B of 0-9 A-Z a-z . _ / ^ ~ - only, no part starting with -'
	case ${ref} in
		*[!0-9A-Za-z._/^~-]*) printf 'holds a character outside the allowed set; expected %s' "${ref_rule}" ;;
		*...*) printf 'holds ...; expected %s' "${ref_rule}" ;;
		*..*..*) printf 'holds .. more than once; expected %s' "${ref_rule}" ;;
		..* | *..) printf 'is a range with an empty end; expected %s' "${ref_rule}" ;;
		-* | *..-*) printf 'has a part starting with -; expected %s' "${ref_rule}" ;;
		*) ;;
	esac
}

# Sets resolved_sha and resolved_short to commit $1 of repo_root, or exits 3.
resolve_commit() {
	# shellcheck disable=SC2310 # its status is git's answer; a failure is reported
	if resolved_sha=$(run_git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null); then
		case ${resolved_sha} in
			'' | *[!0-9a-f]*) ;;
			*)
				resolved_short=$(run_git rev-parse --short "${resolved_sha}") ||
					die 5 "git rev-parse --short failed in ${repo_root}; expected a short sha; try git --version, then rerun"
				return 0
				;;
		esac
	fi
	refuse "--ref ${ref}: $1 does not resolve to a commit in ${repo_root}; expected a commit of that repository"
}

# diff: checks the inputs, writes the diff git prints into a temp file,
# checks it, then moves it into the draft's docs folder.
diff_command() {
	repo_problem=$(repo_root_problem)
	[ -z "${repo_problem}" ] || refuse "--repo ${repo_root}: ${repo_problem}"
	ref_problem=$(ref_syntax_problem)
	[ -z "${ref_problem}" ] || refuse "--ref ${ref}: ${ref_problem}"
	from_sha=''
	case ${ref} in
		*..*)
			resolve_commit "${ref%%..*}"
			from_sha=${resolved_sha} from_short=${resolved_short}
			resolve_commit "${ref#*..}"
			patch_name="diff-${from_short}..${resolved_short}.patch"
			;;
		*)
			resolve_commit "${ref}"
			patch_name="diff-${resolved_short}.patch"
			;;
	esac
	require_open_effort
	diff_temp=$(mktemp "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		die 1 "mktemp could not create a temp file in \${TMPDIR:-/tmp}; expected a writable temp folder; try setting TMPDIR to one, then rerun"
	# shellcheck disable=SC2310 # their status is git's; a failure exits
	if [ -n "${from_sha}" ]; then
		git_without_sensitive_files diff --no-color --no-ext-diff --no-textconv "${from_sha}..${resolved_sha}" >"${diff_temp}" ||
			die 1 "git diff failed in ${repo_root}; its stderr is above; expected the range's diff; try the fix git names, then rerun"
	else
		# shellcheck disable=SC2310 # its status is git's; a failure exits
		git_without_sensitive_files show --no-color --no-ext-diff --no-textconv --no-show-signature "${resolved_sha}" >"${diff_temp}" ||
			die 1 "git show failed in ${repo_root}; its stderr is above; expected the commit's diff; try the fix git names, then rerun"
	fi
	[ -s "${diff_temp}" ] || refuse "--ref ${ref}: the diff is empty; expected a commit or range that changes something"
	# shellcheck disable=SC2310 # it prints the problem; its status only says whether there was one
	diff_problem=$(long_text_problem "${diff_temp}" 'the diff') || true
	[ -z "${diff_problem}" ] || refuse "--ref ${ref}: ${diff_problem}"
	ensure_next_folder
	make_temp "${patch_name}"
	cat "${diff_temp}" >"${temp_file}" ||
		die 1 "could not write the temp file ${temp_file}; expected the diff written; try checking free space, then rerun"
	commit_temp "${next_folder}/${patch_name}"
	printf 'DIFF_FILE: %s\n' "${next_folder}/${patch_name}"
}

command='' mode='' effort_dir='' entry_kind='' entry_value='' entry_why='' docs_of='' docs_of_file='' draft='' expected_fingerprint=''
repo_root='' ref='' seen_options='' tools_checked='' session_id=''
temp_file='' diff_temp='' moved_folder='' locked_files=''
trap clean_up EXIT
# A signal exits through the EXIT trap, so the temp files go and moved docs
# come back on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
require_tools
load_dependencies
resolve_effort
case ${command} in
	docs) docs_command ;;
	add | drop)
		if [ -n "${docs_of}${docs_of_file}" ]; then
			docs_of_command
		else
			entry_command
		fi
		;;
	spec) spec_command ;;
	freeze) freeze_command ;;
	latest) latest_command ;;
	*) diff_command ;;
esac
