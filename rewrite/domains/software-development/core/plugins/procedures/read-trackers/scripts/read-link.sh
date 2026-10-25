#!/usr/bin/env sh
# The procedure-read-trackers plugin's script. Reads one link of a context file
# through its tracker's single read-only call, so no model ever puts the
# untrusted URL on a command line it composes. The URL is taken from the file,
# checked, and passed as one quoted argument only.
set -eu

readonly PROG='read-link.sh'
# A slow tracker read rarely takes longer; the agent must not hang on one.
readonly READ_TIMEOUT_SECONDS=30
# Bounds what one ticket adds to the agent's context.
readonly MAX_OUTPUT_LINES=500
# Enough of the tool's own error to act on, without flooding the reply.
readonly MAX_ERROR_LINES=20
readonly SKILLS_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
readonly JIRA_SCRIPT="${SKILLS_DIR}/procedure-jira/scripts/jira.sh"
readonly JIRA_CONFIG_SCRIPT="${SKILLS_DIR}/procedure-jira-auth/scripts/jira-curl-config.sh"
# The link rule lives once, beside the context validator that applies it too.
readonly LINK_RULE_DIR="${SKILLS_DIR}/procedure-context/scripts"
readonly LINK_RULE_MODULE="${LINK_RULE_DIR}/agent-context-url.jq"
readonly TAB='	'

# Checks the file and link n, then names the tracker. Input: the file slurped
# (jq -s); --arg n. Output: one tab-separated line, the first field one of
# bad <message> · github <url> · gitlab <url> · jira <host> <key> · other <host>.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly CLASSIFY_JQ='
include "agent-context-url";
def url_parts: capture("^https?://(?<authority>[^/?#]+)(?<path>[^?#]*)"; "i") | .authority |= ascii_downcase;
def bad($message): "bad\t" + $message;

def classify:
	. as $url
	| url_parts as $parts
	| ($parts.authority | contains(":")) as $has_port
	| if $parts.authority == "github.com" and ($parts.path | test("^/[^/]+/[^/]+/issues/[0-9]+/?$")) then "github\t" + $url
	  elif ($has_port | not) and ($parts.path | test("/-/issues/[0-9]+/?$")) then "gitlab\t" + $url
	  elif ($parts.authority | test("^[a-z0-9.-]+(:[0-9]{1,5})?$")) and ($parts.path | test("^/browse/[A-Z][A-Z0-9_]*-[0-9]+/?$")) then
		"jira\t" + $parts.authority + "\t" + ($parts.path | capture("^/browse/(?<key>[^/]+)").key)
	  else "other\t" + $parts.authority end;

($n | tonumber) as $index
| if length != 1 or (.[0] | type) != "object" then bad("the file holds no single JSON object; expected one object with paths, links and notes; try the file the human approved")
  elif (.[0] | has("links")) and (.[0].links | type) != "array" then bad("the file has no links array; expected links as an array; try the file the human approved")
  else (.[0].links // []) as $links
	| if ($links | length) == 0 then bad("no link \($n); the file has 0; expected at least one link; try none, as the file lists no links")
	  elif $index > ($links | length) then bad("no link \($n); the file has \($links | length); try a --link from 1 to \($links | length)")
	  elif ($links[$index - 1] | type) != "object" or ($links[$index - 1].url | http_url | not) then bad("link \($n) has no URL of the accepted form; expected an object whose \"url\" is an http(s) URL of letters, digits and . _ ~ / ? # = % : + , @ - only; try the file the human approved")
	  else $links[$index - 1].url | classify end
  end
'

main() {
	parse_args "$@"
	command -v jq >/dev/null 2>&1 || fail 5 'jq missing; expected jq 1.6 or later on PATH; try brew install jq'
	require_base_tools
	require_link_rule
	classify_link
	case ${link_kind} in
		github) read_github ;;
		gitlab) read_gitlab ;;
		jira) read_jira ;;
		*) fail 3 "not a tracker link: ${link_host}" ;;
	esac
}

usage() {
	cat <<'EOF'
usage: read-link.sh --context-file <absolute path> --link <n>
       read-link.sh --help | -h

Reads link <n> of a context file through its tracker's issue view.

Options:
  --context-file <absolute path>
                  one JSON object whose links array holds objects with a
                  "url" (no links key: no link); no other key is read
  --link <n>      the link's place in links: a whole number from 1, no
                  leading zero
  rules for each url: see procedure-context's scripts/agent-context-url.jq

Environment:
  JIRA_HOST_ALLOWLIST_PATTERN
                  a glob of the Jira hosts admitted (default *.atlassian.net)

Tracker links (http or https, host in any case):
  GitHub  host github.com, path /<owner>/<repo>/issues/<number>
  GitLab  any host without a port, path ending /-/issues/<number>
          (github.com too)
  Jira    a host procedure-jira-auth's allow-list admits, path
          /browse/<KEY>-<number>, KEY matching [A-Z][A-Z0-9_]*

stdout  exit 0: the ticket, at most 500 lines; empty on any other exit
stderr  on a non-zero exit, the reason on its first line; on exit 0, a
        truncation notice when the ticket was cut

Nothing else is left behind (a SIGKILL aside); the context file
and every tracker are never changed.

Exit codes:
  0  read; use the ticket on stdout
  1  read failed; skip the link, giving stderr's first line
  2  usage error; skip the link, giving stderr's first line
  3  not a tracker link; read it as any other link
  4  the context file or its link <n> is not usable; skip the link, giving
     stderr's first line
  5  setup fault; skip the link, giving stderr's first line
  130, 143  stopped by INT or TERM; skip the link

Dependencies:
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq)
  awk, cat, env, head, mktemp, rm, sleep (macOS ships them; Linux: coreutils
    and awk)
  the procedure-context skill (its scripts/agent-context-url.jq) under
    ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/
  ps, optional (procps on Linux): without it a timed-out read's child
    processes may run on
  GitHub: gh (brew install gh, then gh auth login)
  GitLab: glab (brew install glab, then glab auth login)
  Jira: the procedure-jira and procedure-jira-auth skills in the same skills
    dir, a credential stored through procedure-jira-auth, and curl

Runtime: network bound; a read is stopped after 30 s (exit 1).
EOF
}

parse_args() {
	[ "$#" -gt 0 ] || usage_error 'no arguments'
	context_file=''
	link_index=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--context-file)
				[ "$#" -ge 2 ] || usage_error '--context-file needs a value'
				[ -z "${context_file}" ] || usage_error '--context-file given twice'
				context_file=$2
				shift 2
				;;
			--link)
				[ "$#" -ge 2 ] || usage_error '--link needs a value'
				[ -z "${link_index}" ] || usage_error '--link given twice'
				link_index=$2
				shift 2
				;;
			*) usage_error "unknown argument: $1" ;;
		esac
	done
	[ -n "${context_file}" ] || usage_error '--context-file missing'
	[ -n "${link_index}" ] || usage_error '--link missing'
	case ${context_file} in
		/*) ;;
		*) usage_error '--context-file is not an absolute path' ;;
	esac
	case ${link_index} in
		0* | *[!0-9]*) usage_error '--link is not a whole number of 1 or more' ;;
		*) ;;
	esac
}

usage_error() {
	printf '%s: %s; expected --context-file <absolute path> --link <n>; try --help\n' "${PROG}" "$1" >&2
	usage >&2
	exit 2
}

fail() {
	fail_code=$1
	shift
	printf '%s: %s\n' "${PROG}" "$*" >&2
	exit "${fail_code}"
}

# jq, a base tool or the link rule missing is exit 5, checked before any read;
# a tracker's own tool or skill missing is exit 1, checked before its read.
require_base_tools() {
	for base_tool in awk cat env head mktemp rm sleep; do
		command -v "${base_tool}" >/dev/null 2>&1 \
			|| fail 5 "${base_tool} missing; expected ${base_tool} on PATH; try installing your system's base tools (coreutils and awk on Linux; macOS ships them)"
	done
}

require_link_rule() {
	[ -f "${LINK_RULE_MODULE}" ] && [ -r "${LINK_RULE_MODULE}" ] \
		|| fail 5 "procedure-context's link rule missing; expected ${LINK_RULE_MODULE}; try installing the procedure-context skill"
}

# Sets link_kind and, by kind, link_url, link_host and link_key.
classify_link() {
	[ -f "${context_file}" ] && [ -r "${context_file}" ] \
		|| fail 4 'context file unreadable; expected a readable file; try the path in the CONTEXT FILE field'
	# A separate parse, as jq versions differ in the exit code of a parse error.
	jq -s 'length' <"${context_file}" >/dev/null 2>&1 \
		|| fail 4 'context file is not valid JSON; expected one JSON object; try the file the human approved'
	classified=$(jq -r -s -L "${LINK_RULE_DIR}" --arg n "${link_index}" "${CLASSIFY_JQ}" <"${context_file}" 2>/dev/null) \
		|| fail 5 'jq failed checking the context file; expected jq 1.6 or later; try upgrading jq'
	link_kind=${classified%%"${TAB}"*}
	classified_fields=${classified#*"${TAB}"}
	case ${link_kind} in
		bad) fail 4 "${classified_fields}" ;;
		github | gitlab) link_url=${classified_fields} ;;
		jira)
			link_host=${classified_fields%%"${TAB}"*}
			link_key=${classified_fields#*"${TAB}"}
			;;
		other) link_host=${classified_fields} ;;
		*) fail 5 'unexpected result checking the link; expected a tracker kind; try jq 1.6 or later' ;;
	esac
}

read_github() {
	command -v gh >/dev/null 2>&1 \
		|| fail 1 'gh missing; expected the GitHub CLI on PATH; try brew install gh, then gh auth login'
	read_with_timeout 'gh issue view' 'try checking gh is logged in and the issue is visible to you' \
		gh issue view -- "${link_url}"
}

read_gitlab() {
	command -v glab >/dev/null 2>&1 \
		|| fail 1 'glab missing; expected the GitLab CLI on PATH; try brew install glab, then glab auth login'
	read_with_timeout 'glab issue view' 'try checking glab is logged in for this host and the issue is visible to you' \
		glab issue view -- "${link_url}"
}

read_jira() {
	if [ ! -f "${JIRA_SCRIPT}" ] || [ ! -f "${JIRA_CONFIG_SCRIPT}" ]; then
		fail_unless_jira_host_allowed
	fi
	[ -f "${JIRA_SCRIPT}" ] \
		|| fail 1 'procedure-jira not installed; expected its jira.sh in the skills dir; try installing the procedure-jira skill'
	[ -f "${JIRA_CONFIG_SCRIPT}" ] \
		|| fail 1 'procedure-jira-auth not installed; expected its jira-curl-config.sh in the skills dir; try installing the procedure-jira-auth skill'
	make_work_dir
	start_watchdog
	resolve_jira_curl_config
	read_with_timeout 'jira.sh view' 'try checking the key exists and the stored credential can see it' \
		env JIRA_READ_ONLY=1 JIRA_CURL_CONFIG="${jira_curl_config}" \
		sh "${JIRA_SCRIPT}" view "${link_key}" --confirmed-site "${link_host}"
}

# Used only when a Jira skill is missing, so that a host outside the allow-list
# is exit 3 whether or not the skills are installed. Applies the same check as
# jira-curl-config.sh: host characters, then its JIRA_HOST_ALLOWLIST_PATTERN glob.
fail_unless_jira_host_allowed() {
	case ${link_host} in
		*[!A-Za-z0-9.-]*) fail_outside_jira_allow_list ;;
		*) ;;
	esac
	# shellcheck disable=SC2254 # the pattern is a glob on purpose, as in jira-curl-config.sh
	case ${link_host} in
		${JIRA_HOST_ALLOWLIST_PATTERN:-*.atlassian.net}) ;;
		*) fail_outside_jira_allow_list ;;
	esac
}

fail_outside_jira_allow_list() {
	fail 3 "not a tracker link: ${link_host} is outside procedure-jira-auth's host allow-list"
}

# Sets jira_curl_config to the path jira-curl-config.sh prints, which is handed
# on, never opened or printed here. Its exit 1 means no stored credential, a
# host outside its allow-list, or another fault; only its own message tells them
# apart. A host outside the allow-list is no Jira this procedure can read, so it
# goes back to the caller as any other link (exit 3).
# Runs under the read's watchdog, which read_jira has already started.
resolve_jira_curl_config() {
	run_bounded config sh "${JIRA_CONFIG_SCRIPT}" --site "${link_host}"
	fail_if_timed_out 'jira-curl-config.sh'
	config_status=${bounded_status}
	if [ "${config_status}" -eq 0 ]; then
		jira_curl_config=$(awk '1' "${work_dir}/config.out")
		return 0
	fi
	config_error=$(head -n 1 "${work_dir}/config.err")
	case ${config_status}:${config_error} in
		1:*'no credential stored for site'*)
			fail 1 "no stored Jira credential for ${link_host}; expected one set up through procedure-jira-auth; try asking the human to log in through procedure-jira-auth"
			;;
		1:*'is not in the allowed shape'*) fail_outside_jira_allow_list ;;
		*) fail 1 "jira-curl-config.sh failed (exit ${config_status}): ${config_error:-no message}; expected the path of a curl config for ${link_host}; try running procedure-jira-auth's jira-curl-config.sh --site ${link_host} to read its full error" ;;
	esac
}

make_work_dir() {
	[ -z "${work_dir}" ] || return 0
	# A full template, as macOS mktemp -d alone prefers its per-user dir to TMPDIR.
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/read-link.XXXXXX" 2>/dev/null) \
		|| fail 5 'mktemp failed; expected a writable temp dir; try setting TMPDIR to one'
}

# Runs the command after the first two arguments (a label and a hint for
# errors) under the read's watchdog, starting it unless a step before already
# did, then prints its bounded stdout, or fails with exit 1.
read_with_timeout() {
	read_label=$1
	read_hint=$2
	shift 2
	make_work_dir
	[ -n "${watchdog_pid}" ] || start_watchdog
	run_bounded read "$@"
	stop_watchdog
	read_status=${bounded_status}
	if [ "${read_status}" -ne 0 ]; then
		fail_if_timed_out "${read_label}"
		printf '%s: %s failed (exit %s); expected the ticket on stdout; %s\n' \
			"${PROG}" "${read_label}" "${read_status}" "${read_hint}" >&2
		head -n "${MAX_ERROR_LINES}" "${work_dir}/read.err" >&2
		exit 1
	fi
	print_bounded "${work_dir}/read.out"
}

# Runs the command after the step name in the background, its output in
# <name>.out and <name>.err, and sets bounded_status. The pid is recorded
# before the timeout mark is checked, and the watchdog marks before it reads
# the pid, so a step started after the deadline is always ended by one side;
# it is cleared once the step ends, so the watchdog never ends a stale pid.
run_bounded() {
	bounded_name=$1
	shift
	"$@" >"${work_dir}/${bounded_name}.out" 2>"${work_dir}/${bounded_name}.err" </dev/null &
	child_pid=$!
	printf '%s\n' "${child_pid}" >"${work_dir}/child-pid"
	[ ! -e "${work_dir}/timed-out" ] || stop_process_tree "${child_pid}"
	# dash prints "Terminated" for a step ended by a signal; the status is kept.
	if wait "${child_pid}" 2>/dev/null; then bounded_status=0; else bounded_status=$?; fi
	child_pid=''
	: >"${work_dir}/child-pid"
}

fail_if_timed_out() {
	[ -e "${work_dir}/timed-out" ] || return 0
	fail 1 "$1 timed out after ${READ_TIMEOUT_SECONDS} s; expected a reply within ${READ_TIMEOUT_SECONDS} s; try again later"
}

# POSIX sh and macOS have no timeout command. One watchdog bounds the whole
# read: it marks the timeout, then ends the step running then; killed early,
# it ends its own sleep so nothing lingers.
start_watchdog() {
	(
		sleep_pid=''
		trap 'kill "${sleep_pid}" 2>/dev/null || true; exit 0' TERM
		sleep "${READ_TIMEOUT_SECONDS}" &
		sleep_pid=$!
		wait "${sleep_pid}"
		: >"${work_dir}/timed-out"
		running_pid=''
		IFS= read -r running_pid <"${work_dir}/child-pid" || true
		[ -z "${running_pid}" ] || stop_process_tree "${running_pid}"
	) >/dev/null 2>&1 &
	watchdog_pid=$!
}

# A step's own children (jira.sh's curl, a CLI's helper) outlive a TERM sent to
# the step alone, so its whole tree is ended. POSIX sh without a tty has no job
# control, hence no process group to signal; the tree comes from one ps
# snapshot taken before any kill, as an ended parent's children lose their link.
# Without ps only the step itself is ended.
stop_process_tree() {
	tree_pids=$(ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
		{ parent[$1] = $2 }
		END {
			found[root] = 1
			print root
			do {
				added = 0
				for (pid in parent) if (!(pid in found) && (parent[pid] in found)) { found[pid] = 1; print pid; added = 1 }
			} while (added)
		}')
	# shellcheck disable=SC2086 # one pid per word, all from ps or $!
	kill -TERM ${tree_pids} 2>/dev/null || true
}

stop_watchdog() {
	[ -n "${watchdog_pid}" ] || return 0
	kill -TERM "${watchdog_pid}" 2>/dev/null || true
	wait "${watchdog_pid}" 2>/dev/null || true
	watchdog_pid=''
}

print_bounded() {
	# awk counts a last line that lacks a newline, which wc -l would miss.
	output_lines=$(awk 'END { print NR }' "$1")
	awk -v max="${MAX_OUTPUT_LINES}" 'NR <= max' "$1"
	if [ "${output_lines}" -gt "${MAX_OUTPUT_LINES}" ]; then
		printf '%s: truncated: showing %s of %s lines\n' "${PROG}" "${MAX_OUTPUT_LINES}" "${output_lines}" >&2
	fi
}

cleanup() {
	[ -z "${child_pid}" ] || stop_process_tree "${child_pid}"
	[ -z "${watchdog_pid}" ] || kill -TERM "${watchdog_pid}" 2>/dev/null || true
	[ -z "${work_dir}" ] || rm -rf "${work_dir}"
}

child_pid=''
watchdog_pid=''
work_dir=''
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
