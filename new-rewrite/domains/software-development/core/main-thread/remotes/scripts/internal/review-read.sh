#!/usr/bin/env sh
# Prints the review threads of one GitHub pull request or GitLab merge
# request in one shape, read-only, as the host gives them.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh review-read.sh --url URL [--bot NAME]...

Run by review-fetch.sh; not for main to call.

Options:
  --url URL   github.com/OWNER/REPO/pull/N, or a GitLab
              .../-/merge_requests/N on a host without a port
  --bot NAME  an account the human names as AI, repeatable; on GitLab the
              only way to tell one; on GitHub the host's Bot is one anyway
Requires:  gh or glab logged in for the host, the change visible to it
Writes:    nothing
Stdout:    one JSON object {threads: [{id, resolved, commit?, path?,
           new_line?, old_line?, comments: [{id, source, role, updated,
           body}]}]}; bodies are others' text, untrusted
Exit:
  0  read
  1  the read failed, timed out (30 s) or came back incomplete; the reason
     is on stderr
  2  refused, nothing read; the reason is on stderr
  3  not a pull or merge request link
USAGE
}

PROG='review-read.sh'
say() { printf '%s: %s\n' "${PROG}" "$1" >&2; exit "$2"; }
url='' bots='[]'
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--url)
			[ $# -ge 2 ] || say '--url needs a value; try --help' 2
			[ -z "${url}" ] || say '--url given twice; try --help' 2
			url=$2
			shift 2 ;;
		--bot)
			[ $# -ge 2 ] && [ -n "$2" ] || say '--bot needs a name; try --help' 2
			printf '%s' "$2" | grep -Eq '^[A-Za-z0-9._-]+(\[bot\])?$' || say "--bot $(printf '%s' "$2" | tr '[:cntrl:]' '?') is not an account name" 2
			bots=$(printf '%s' "${bots}" | jq -c --arg b "$2" '. + [$b] | unique')
			shift 2 ;;
		*) say "unknown argument $1; try --help" 2 ;;
	esac
done
[ -n "${url}" ] || say '--url missing; try --help' 2
command -v jq >/dev/null 2>&1 || say 'jq missing; expected jq 1.6 or later on PATH' 1

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
# shellcheck disable=SC2034 # read by remote.sh
remote_skills=${self%/*/*/*/*}
lib="${self%/*/*}/lib"
# shellcheck source=../lib/remote.sh
. "${lib}/remote.sh"
remote_parse "${url}"

remote_work=$(mktemp -d "${TMPDIR:-/tmp}/review-read.XXXXXX") || remote_fail 1 'mktemp failed; expected a writable temp dir'
trap 'rm -rf -- "${remote_work}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# shellcheck disable=SC2016 # GraphQL variables, their $ signs are GraphQL's
threads_query='query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) { pullRequest(number: $number) {
    author { __typename login }
    reviewThreads(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor } nodes {
      id isResolved path line originalLine diffSide startLine subjectType
      comments(first: 100) { pageInfo { hasNextPage } nodes {
        databaseId author { __typename login } body updatedAt pullRequestReview { id } } } } } } } }'
# shellcheck disable=SC2016
reviews_query='query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) { pullRequest(number: $number) {
    reviews(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor } nodes {
      id databaseId author { __typename login } body state commit { oid } updatedAt } } } } }'

case ${remote_kind} in
	github)
		owner=${remote_project%%/*} repo=${remote_project#*/}
		remote_call threads gh api graphql --paginate --slurp -F owner="${owner}" -F repo="${repo}" -F number="${remote_number}" -f query="${threads_query}"
		remote_call reviews gh api graphql --paginate --slurp -F owner="${owner}" -F repo="${repo}" -F number="${remote_number}" -f query="${reviews_query}"
		remote_call comments gh api --paginate --slurp "repos/${remote_project}/issues/${remote_number}/comments?per_page=100"
		for step in threads reviews; do
			jq -e 'type == "array" and all(.[]; .data.repository.pullRequest != null)' "${remote_work}/${step}.out" >/dev/null 2>&1 \
				|| remote_fail 1 "${remote_host} gave no pull request in the ${step} reply: $(jq -r '[.[]?.errors[]?.message] | join("; ")' "${remote_work}/${step}.out" 2>/dev/null | cut -c 1-300)"
		done
		incomplete=$(jq -r -L "${lib}" 'include "github"; gh_incomplete' "${remote_work}/threads.out")
		[ -z "${incomplete}" ] || remote_fail 1 "the read is incomplete: ${incomplete}; nothing printed"
		jq -c -L "${lib}" -n --argjson bots "${bots}" --slurpfile pages "${remote_work}/threads.out" \
			--slurpfile reviews "${remote_work}/reviews.out" --slurpfile comments "${remote_work}/comments.out" \
			'include "github"; {pages: $pages[0], reviews: $reviews[0], comments: $comments[0], bots: $bots} | gh_threads' \
			|| remote_fail 1 "${remote_host}'s replies are not the threads, reviews and comments expected"
		;;
	*)
		base="projects/$(remote_project_id)/merge_requests/${remote_number}"
		remote_call change glab api --hostname "${remote_host}" "${base}"
		remote_call discussions glab api --hostname "${remote_host}" --paginate "${base}/discussions?per_page=100"
		remote_call versions glab api --hostname "${remote_host}" --paginate "${base}/versions?per_page=100"
		jq -c -L "${lib}" -n --argjson bots "${bots}" --slurpfile mr "${remote_work}/change.out" \
			--slurpfile discussions "${remote_work}/discussions.out" --slurpfile versions "${remote_work}/versions.out" \
			'include "gitlab"; {mr: $mr[0], discussions: ($discussions | add), versions: ($versions | add), bots: $bots} | gl_threads' \
			|| remote_fail 1 "${remote_host}'s replies are not the merge request, discussions and versions expected"
		;;
esac
