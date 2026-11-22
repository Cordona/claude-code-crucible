#!/usr/bin/env sh
# Prints one GitHub or GitLab issue, its body and comments, read-only. The
# URL is checked by the safe-link rule and passed on as one argument only.
set -eu
umask 077

readonly PROG='tracker-read.sh'
# A slow tracker rarely takes longer; a caller must not hang on one.
readonly CALL_TIMEOUT_SECONDS=30
# Bounds what one ticket adds to a reader's context.
readonly MAX_LINES=500
# Enough of a tool's own error to act on.
readonly MAX_ERROR_LINES=20

usage() {
	cat <<'USAGE'
usage: sh tracker-read.sh --url URL
       sh tracker-read.sh --help | -h

Prints one tracker issue as markdown: its title, state, author, body and
comments, oldest first. Read-only: it runs only the trackers' view and read
calls. Each call stops after 30 s; the output stops at 500 lines.

  --url URL   an http(s) link of letters, digits and . _ ~ / ? # = % : + , @ -
              only (other characters percent-encoded)

Tracker links:
  GitHub  host github.com, path /<owner>/<repo>/issues/<n>; needs gh
  GitLab  any host without a port, path ending /-/issues/<n>; needs glab
Not covered: pull and merge requests, GitHub Enterprise hosts, Jira. They
are not tracker links here (exit 3). An /issues/<n> link whose number the
tracker resolves to a pull request is read as the tracker gives it.

Comments that can't be read (GitLab without a login, for one) leave the
body read and a "Comments not read" line in their place.

stdout  exit 0: the ticket
stderr  the reason, on its first line, on any other exit; on exit 0, the line
        "tracker-read.sh: truncated: showing 500 of <N> lines" when cut
Exit: 0 read; 1 the read failed; 2 a usage error or a refused URL;
      3 not a tracker link: read it as any other link
Needs: POSIX sh, jq 1.6+, and gh or glab for its tracker
USAGE
}

fail() {
	fail_code=$1
	shift
	printf '%s: %s\n' "${PROG}" "$*" >&2
	exit "${fail_code}"
}
usage_error() { fail 2 "$1; try --help"; }

url=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--url)
			[ $# -ge 2 ] || usage_error '--url needs a value'
			[ -z "${url}" ] || usage_error '--url given twice'
			url=$2
			shift 2 ;;
		*) usage_error "unknown argument $1" ;;
	esac
done
[ -n "${url}" ] || usage_error '--url missing'

# The safe-link rule: the same characters core's context accepts for a link.
printf '%s' "${url}" | grep -Eq '^[Hh][Tt][Tt][Pp][Ss]?://[A-Za-z0-9.-]+(:[0-9]+)?([/?#][A-Za-z0-9._~/?#=%:+,@-]*)?$' \
	|| fail 2 'the URL is not of the accepted form; expected an http(s) link of letters, digits and . _ ~ / ? # = % : + , @ - only'
command -v jq >/dev/null 2>&1 || fail 1 'jq missing; expected jq 1.6 or later on PATH'

rest=${url#*://}
authority=$(printf '%s' "${rest%%[/?#]*}" | tr 'A-Z' 'a-z')
path=${rest#"${rest%%[/?#]*}"}
path=${path%%[?#]*}
host=${authority%%:*}

kind=other
if [ "${authority}" = github.com ] && printf '%s' "${path}" | grep -Eq '^/[^/]+/[^/]+/issues/[0-9]+/?$'; then
	kind=github
elif [ "${authority}" != github.com ] && [ "${authority}" = "${host}" ] && printf '%s' "${path}" | grep -Eq '/-/issues/[0-9]+/?$'; then
	kind=gitlab
fi
[ "${kind}" != other ] || fail 3 "not a tracker link: ${authority}${path}"

work=$(mktemp -d "${TMPDIR:-/tmp}/tracker-read.XXXXXX") || fail 1 'mktemp failed; expected a writable temp dir'
trap 'rm -rf -- "${work}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Runs the command after the step name, its output in <name>.out and
# <name>.err, and sets status. A watchdog ends it after the timeout and marks
# <name>.late; a watchdog ended early ends its own sleep.
run_timed() {
	step=$1
	shift
	"$@" >"${work}/${step}.out" 2>"${work}/${step}.err" </dev/null &
	call_pid=$!
	(
		trap 'kill "${sleep_pid}" 2>/dev/null; exit 0' TERM
		sleep "${CALL_TIMEOUT_SECONDS}" &
		sleep_pid=$!
		wait "${sleep_pid}"
		: >"${work}/${step}.late"
		kill -TERM "${call_pid}" 2>/dev/null
	) >/dev/null 2>&1 &
	watch_pid=$!
	if wait "${call_pid}" 2>/dev/null; then status=0; else status=$?; fi
	kill -TERM "${watch_pid}" 2>/dev/null || true
	wait "${watch_pid}" 2>/dev/null || true
}

# The reason a failed step gives: its timeout, or its tool's own error.
step_error() {
	if [ -e "${work}/$1.late" ]; then
		printf 'timed out after %s s' "${CALL_TIMEOUT_SECONDS}"
	else
		printf 'exit %s: %s' "${status}" "$(tr -s '[:space:]' ' ' <"${work}/$1.err" | cut -c 1-300)"
	fi
}

fail_step() {
	printf '%s: %s failed (%s); expected the issue; try checking %s is logged in for %s and the issue is visible to you\n' \
		"${PROG}" "$2" "$(step_error "$1")" "$3" "${host}" >&2
	head -n "${MAX_ERROR_LINES}" "${work}/$1.err" >&2
	exit 1
}

# shellcheck disable=SC2016 # jq programs, their $ signs are jq's
render_jq='
def line: if . == null then "" else tostring end;
"# \(.title | line)",
"",
"\(.url | line) · \(.state | line) · by \(.author | line) · \(.created | line)",
"",
(.body | line),
"",
(if .comments_error then "## Comments not read (\(.comments_error))"
 else "## Comments (\(.comments | length))",
  (.comments[] | "", "### \(.author | line), \(.created | line)", "", (.body | line))
 end)
'

case ${kind} in
	github)
		command -v gh >/dev/null 2>&1 || fail 1 'gh missing; expected the GitHub CLI on PATH; try brew install gh, then gh auth login'
		run_timed issue gh issue view --json title,state,author,url,createdAt,body,comments -- "${url}"
		[ "${status}" -eq 0 ] || fail_step issue 'gh issue view' gh
		jq -r '{title, state, url, author: .author.login, created: .createdAt, body,
			comments: [.comments[] | {author: .author.login, created: .createdAt, body}]}' \
			"${work}/issue.out" >"${work}/ticket.json" 2>/dev/null \
			|| fail 1 'gh issue view gave no issue JSON; expected title, body and comments'
		;;
	gitlab)
		command -v glab >/dev/null 2>&1 || fail 1 'glab missing; expected the GitLab CLI on PATH; try brew install glab, then glab auth login'
		run_timed issue glab issue view -F json -- "${url}"
		[ "${status}" -eq 0 ] || fail_step issue 'glab issue view' glab
		ids=$(jq -r '"\(.project_id) \(.iid)"' "${work}/issue.out" 2>/dev/null) \
			|| fail 1 'glab issue view gave no issue JSON; expected project_id and iid'
		project_id=${ids% *}
		iid=${ids#* }
		comments_error=''
		case ${project_id}:${iid} in
			*[!0-9:]* | :* | *:) comments_error='the issue has no project id' ;;
			*)
				run_timed notes glab api --hostname "${host}" "projects/${project_id}/issues/${iid}/notes?sort=asc&order_by=created_at&per_page=100"
				if [ "${status}" -ne 0 ]; then
					comments_error=$(step_error notes)
				elif ! jq -e 'type == "array"' "${work}/notes.out" >/dev/null 2>&1; then
					comments_error='the notes reply is not a list'
				fi ;;
		esac
		[ -n "${comments_error}" ] || jq '[.[] | select(.system | not) | {author: .author.username, created: .created_at, body}]' \
			"${work}/notes.out" >"${work}/comments.json" 2>/dev/null || comments_error='the notes reply is not a list'
		[ -z "${comments_error}" ] || printf '[]' >"${work}/comments.json"
		jq --arg error "${comments_error}" --slurpfile comments "${work}/comments.json" \
			'{title, state, url: .web_url, author: .author.username, created: .created_at, body: .description,
			comments: $comments[0], comments_error: (if $error == "" then null else $error end)}' \
			"${work}/issue.out" >"${work}/ticket.json" 2>/dev/null \
			|| fail 1 'glab issue view gave no issue JSON; expected title and description'
		;;
esac

jq -r "${render_jq}" "${work}/ticket.json" >"${work}/ticket.md" || fail 1 'could not render the issue'
lines=$(awk 'END { print NR }' "${work}/ticket.md")
awk -v max="${MAX_LINES}" 'NR <= max' "${work}/ticket.md"
[ "${lines}" -le "${MAX_LINES}" ] || printf '%s: truncated: showing %s of %s lines\n' "${PROG}" "${MAX_LINES}" "${lines}" >&2
