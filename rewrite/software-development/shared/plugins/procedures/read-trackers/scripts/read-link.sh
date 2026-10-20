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
readonly TAB='	'

# Checks the file and link n, then names the tracker. Input: the file slurped
# (jq -s); --arg n. Output: one tab-separated line, the first field one of
# bad <message> · github <url> · gitlab <url> · jira <host> <key> · other <host>.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly CLASSIFY_JQ='
# Copy of http_url in flow-agent-initialization scripts/02-agent-context/agent-context-validator.jq;
# keep both in step. It admits no character that quotes, substitutes, redirects,
# splits or chains in a shell.
def http_url: type == "string" and test("^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?([/?#][A-Za-z0-9._~/?#=%:+,@-]*)?$"; "i");
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
  elif (.[0].links | type) != "array" then bad("the file has no links array; expected links as an array; try the file the human approved")
  else .[0].links as $links
	| if ($links | length) == 0 then bad("no link \($n); the file has 0; expected at least one link; try none, as the file lists no links")
	  elif $index > ($links | length) then bad("no link \($n); the file has \($links | length); try a --link from 1 to \($links | length)")
	  elif ($links[$index - 1] | type) != "object" or ($links[$index - 1].url | http_url | not) then bad("link \($n) has no URL of the accepted form; expected {\"url\", \"why\"} with an http(s) URL of letters, digits and . _ ~ / ? # = % : + , @ - only; try fetching it another way")
	  else $links[$index - 1].url | classify end
  end
'

main() {
	parse_args "$@"
	command -v jq >/dev/null 2>&1 || fail 5 'jq missing; expected jq 1.6 or later on PATH; try brew install jq'
	require_base_tools
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

The procedure-read-trackers plugin's tracker read. Reads link <n> (1-based)
of the context file's links through its tracker's one read-only call:
gh issue view, glab issue view, or procedure-jira's jira.sh view with
JIRA_READ_ONLY=1. stdout: the ticket, at most 500 lines.

Exit codes:
  0    read, the ticket on stdout
  1    read failed (tool missing, not logged in, network, timeout after 30 s,
       private or missing ticket, no stored Jira credential, tool non-zero)
  2    usage error
  3    not a tracker link (stdout empty)
  4    context file unreadable, not one JSON object, no links, no link <n>,
       or a URL not of the accepted form
  5    internal error, or jq missing
  130  interrupted (INT)
  143  terminated (TERM)

Dependencies: jq 1.6+; the base tools awk, head, mktemp, sleep and kill;
per read, gh, glab, or the procedure-jira and procedure-jira-auth skills
under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/.
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

require_base_tools() {
	for base_tool in awk head mktemp sleep kill; do
		command -v "${base_tool}" >/dev/null 2>&1 \
			|| fail 5 "${base_tool} missing; expected ${base_tool} on PATH; try installing your system's base tools (coreutils, awk and procps on Linux; macOS ships them)"
	done
}

# Sets link_kind and, by kind, link_url, link_host and link_key.
classify_link() {
	[ -f "${context_file}" ] && [ -r "${context_file}" ] \
		|| fail 4 'context file unreadable; expected a readable file; try the path in the CONTEXT FILE field'
	# A separate parse, as jq versions differ in the exit code of a parse error.
	jq -s 'length' <"${context_file}" >/dev/null 2>&1 \
		|| fail 4 'context file is not valid JSON; expected one JSON object; try the file the human approved'
	classified=$(jq -r -s --arg n "${link_index}" "${CLASSIFY_JQ}" <"${context_file}" 2>/dev/null) \
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
	[ -f "${JIRA_SCRIPT}" ] \
		|| fail 1 'procedure-jira not installed; expected its jira.sh in the skills dir; try installing the procedure-jira skill'
	[ -f "${JIRA_CONFIG_SCRIPT}" ] \
		|| fail 1 'procedure-jira-auth not installed; expected its jira-curl-config.sh in the skills dir; try installing the procedure-jira-auth skill'
	resolve_jira_curl_config
	read_with_timeout 'jira.sh view' 'try checking the key exists and the stored credential can see it' \
		env JIRA_READ_ONLY=1 JIRA_CURL_CONFIG="${jira_curl_config}" \
		sh "${JIRA_SCRIPT}" view "${link_key}" --confirmed-site "${link_host}"
}

# Sets jira_curl_config to the path jira-curl-config.sh prints, which is handed
# on, never opened or printed here. Its exit 1 means either no stored credential
# or a host outside its allowed shape; only its own message tells them apart.
resolve_jira_curl_config() {
	make_work_dir
	if jira_curl_config=$(sh "${JIRA_CONFIG_SCRIPT}" --site "${link_host}" 2>"${work_dir}/config-stderr"); then
		return 0
	else
		config_status=$?
	fi
	config_error=$(head -n 1 "${work_dir}/config-stderr")
	case ${config_status}:${config_error} in
		1:*'no credential stored for site'*)
			fail 1 "no stored Jira credential for ${link_host}; expected one set up through procedure-jira-auth; try asking the human to log in through procedure-jira-auth"
			;;
		*) fail 1 "jira-curl-config.sh failed (exit ${config_status}): ${config_error:-no message}; expected the path of a curl config for ${link_host}; try running procedure-jira-auth's jira-curl-config.sh --site ${link_host} to read its full error" ;;
	esac
}

make_work_dir() {
	[ -z "${work_dir}" ] || return 0
	work_dir=$(mktemp -d) || fail 5 'mktemp failed; expected a writable temp dir; try setting TMPDIR'
}

# Runs the command after the first two arguments (a label and a hint for
# errors) with a watchdog, then prints its bounded stdout, or fails with exit 1.
read_with_timeout() {
	read_label=$1
	read_hint=$2
	shift 2
	make_work_dir
	"$@" >"${work_dir}/stdout" 2>"${work_dir}/stderr" </dev/null &
	child_pid=$!
	start_watchdog
	if wait "${child_pid}"; then read_status=0; else read_status=$?; fi
	child_pid=''
	stop_watchdog
	if [ "${read_status}" -ne 0 ]; then
		if [ -e "${work_dir}/timed-out" ]; then
			fail 1 "${read_label} timed out after ${READ_TIMEOUT_SECONDS} s; expected a reply within ${READ_TIMEOUT_SECONDS} s; try again later"
		fi
		printf '%s: %s failed (exit %s); expected the ticket on stdout; %s\n' \
			"${PROG}" "${read_label}" "${read_status}" "${read_hint}" >&2
		head -n "${MAX_ERROR_LINES}" "${work_dir}/stderr" >&2
		exit 1
	fi
	print_bounded "${work_dir}/stdout"
}

# POSIX sh and macOS have no timeout command. The watchdog marks the timeout,
# then ends the read; killed early, it ends its own sleep so nothing lingers.
start_watchdog() {
	(
		sleep_pid=''
		trap 'kill "${sleep_pid}" 2>/dev/null || true; exit 0' TERM
		sleep "${READ_TIMEOUT_SECONDS}" &
		sleep_pid=$!
		wait "${sleep_pid}"
		: >"${work_dir}/timed-out"
		kill -TERM "${child_pid}" 2>/dev/null || true
	) >/dev/null 2>&1 &
	watchdog_pid=$!
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
	[ -z "${child_pid}" ] || kill -TERM "${child_pid}" 2>/dev/null || true
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
