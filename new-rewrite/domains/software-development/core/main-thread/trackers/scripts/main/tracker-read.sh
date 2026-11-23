#!/usr/bin/env sh
# Prints one GitHub or GitLab issue, its body and comments, read-only. The
# URL is checked by the safe-link rule and passed on as one argument only.
# shellcheck disable=SC2312 # a read inside a message only shortens the message
set -eu
umask 077

readonly PROG='tracker-read.sh'
# A slow tracker rarely takes longer; a caller must not hang on one.
readonly CALL_TIMEOUT_SECONDS=30
# run-timed.sh's exit for a command it stopped at the limit.
readonly TIMED_OUT=124
# Bounds what one issue adds to a reader's context.
readonly MAX_LINES=500
# Enough of a tool's own error to act on.
readonly MAX_ERROR_LINES=20

usage() {
	cat <<'USAGE'
usage: sh tracker-read.sh --url URL

Prints one GitHub or GitLab issue as markdown. Use it when the human points
at an issue link to read; to keep it in an effort's context, use
context-add-issue.sh.

Options:
  --url URL  the issue link: host github.com only, path /OWNER/REPO/issues/N;
             or GitLab: any host without a port, path ending /-/issues/N
Requires:  gh or glab logged in for the link's host, the issue visible to it
Writes:    nothing
Stdout:    the issue: title, link, state, author, date, body, then comments
           oldest first (GitLab: the first 100), at most 500 lines; the line
           "## Comments not read (REASON)" replaces comments it can't read;
           nothing on any other exit
Exit:
  0  read; when cut, stderr gets "tracker-read.sh: truncated: showing 500
     of N lines"
  1  the read failed or a tracker call timed out after 30 s; the reason is
     on stderr
  2  refused, nothing changed; the reason is on stderr
  3  not an issue link (pull or merge request, Jira, other): read it as any
     other link
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
# dev-base is found as a neighbour skill: this script's skills folder, cut
# from its own path as text, so a skill link holds.
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
run_timed_script="${self%/*/*/*/*}/dev-base/scripts/internal/run-timed.sh"
[ -f "${run_timed_script}" ] || fail 2 "dev-base isn't beside this skill (expected ${run_timed_script}); install first"

rest=${url#*://}
authority=$(printf '%s' "${rest%%[/?#]*}" | tr '[:upper:]' '[:lower:]')
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

# Runs the command after the step name through dev-base's run-timed.sh, its
# output in <name>.out and <name>.err, and sets status; the runner stops it,
# with everything it started, after the timeout.
run_timed() {
	step=$1
	shift
	status=0
	sh "${run_timed_script}" --seconds "${CALL_TIMEOUT_SECONDS}" -- "$@" \
		>"${work}/${step}.out" 2>"${work}/${step}.err" </dev/null || status=$?
}

# The reason a failed step gives: its timeout, or its tool's own error.
step_error() {
	if [ "${status}" -eq "${TIMED_OUT}" ]; then
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

# shellcheck disable=SC2249 # kind is github or gitlab here; other exited 3 above
case ${kind} in
	github)
		command -v gh >/dev/null 2>&1 || fail 1 'gh missing; expected the GitHub CLI on PATH; try brew install gh, then gh auth login'
		run_timed issue gh issue view --json title,state,author,url,createdAt,body,comments -- "${url}"
		[ "${status}" -eq 0 ] || fail_step issue 'gh issue view' gh
		jq -r '{title, state, url, author: .author.login, created: .createdAt, body,
			comments: [.comments[] | {author: .author.login, created: .createdAt, body}]}' \
			"${work}/issue.out" >"${work}/issue.json" 2>/dev/null \
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
			"${work}/issue.out" >"${work}/issue.json" 2>/dev/null \
			|| fail 1 'glab issue view gave no issue JSON; expected title and description'
		;;
esac

jq -r "${render_jq}" "${work}/issue.json" >"${work}/issue.md" || fail 1 'could not render the issue'
lines=$(awk 'END { print NR }' "${work}/issue.md")
awk -v max="${MAX_LINES}" 'NR <= max' "${work}/issue.md"
[ "${lines}" -le "${MAX_LINES}" ] || printf '%s: truncated: showing %s of %s lines\n' "${PROG}" "${MAX_LINES}" "${lines}" >&2
