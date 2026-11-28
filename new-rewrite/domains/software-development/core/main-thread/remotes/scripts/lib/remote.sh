# What remotes' read scripts share: the change's link taken apart, and a host
# call under a time limit. Sourced; the caller sets PROG and remote_skills
# (the skills folder), and has a work folder in remote_work.
# shellcheck shell=sh disable=SC2034,SC2154 # the variables are shared with the caller

# A slow host rarely takes longer; a caller must not hang on one.
readonly REMOTE_CALL_SECONDS=30
# run-timed.sh's exit for a command it stopped at the limit.
readonly REMOTE_TIMED_OUT=124

remote_fail() {
	remote_code=$1
	shift
	printf '%s: %s\n' "${PROG}" "$*" >&2
	exit "${remote_code}"
}

# Takes the change's link apart: sets remote_kind (github or gitlab),
# remote_host, remote_project (OWNER/REPO, or GitLab's project path),
# remote_number and remote_url (the link without query or fragment).
# Exits 2 on a link that isn't safe, 3 on one that is no pull or merge
# request.
remote_parse() {
	safe_link="${remote_skills}/dev-base/scripts/internal/safe-link.sh"
	[ -f "${safe_link}" ] || remote_fail 2 "dev-base isn't beside this skill (expected ${safe_link}); install first"
	link=$(sh "${safe_link}" --url "$1") || exit 2
	remote_authority=$(printf '%s' "${link}" | jq -r '.authority')
	remote_host=$(printf '%s' "${link}" | jq -r '.host')
	path=$(printf '%s' "${link}" | jq -r '.path')
	path=${path%/}
	remote_kind=''
	if [ "${remote_authority}" = github.com ] && printf '%s' "${path}" | grep -Eq '^/[^/]+/[^/]+/pull/[0-9]+$'; then
		remote_kind=github
		remote_number=${path##*/}
		remote_project=${path#/}
		remote_project=${remote_project%/pull/*}
	elif [ "${remote_authority}" != github.com ] && [ "${remote_authority}" = "${remote_host}" ] \
		&& printf '%s' "${path}" | grep -Eq '^/[^/]+(/[^/]+)+/-/merge_requests/[0-9]+$'; then
		remote_kind=gitlab
		remote_number=${path##*/}
		remote_project=${path#/}
		remote_project=${remote_project%/-/merge_requests/*}
	fi
	[ -n "${remote_kind}" ] || remote_fail 3 "not a pull or merge request link: ${remote_authority}${path}; expected github.com/OWNER/REPO/pull/N or a GitLab .../-/merge_requests/N on a host without a port"
	remote_url="https://${remote_authority}${path}"
	case ${remote_kind} in
		github) command -v gh >/dev/null 2>&1 || remote_fail 1 'gh missing; expected the GitHub CLI on PATH; try brew install gh, then gh auth login' ;;
		*) command -v glab >/dev/null 2>&1 || remote_fail 1 'glab missing; expected the GitLab CLI on PATH; try brew install glab, then glab auth login' ;;
	esac
}

# GitLab's project path as one URL segment.
remote_project_id() {
	printf '%s' "${remote_project}" | jq -sRr '@uri'
}

# Runs one host call, its output in remote_work/STEP.out; stops on failure
# with the tool's own error. Usage: remote_call STEP COMMAND [ARG]...
remote_call() {
	step=$1
	shift
	run_timed="${remote_skills}/dev-base/scripts/internal/run-timed.sh"
	status=0
	sh "${run_timed}" --seconds "${REMOTE_CALL_SECONDS}" -- "$@" \
		>"${remote_work}/${step}.out" 2>"${remote_work}/${step}.err" </dev/null || status=$?
	[ "${status}" -eq 0 ] && return 0
	if [ "${status}" -eq "${REMOTE_TIMED_OUT}" ]; then
		reason="timed out after ${REMOTE_CALL_SECONDS} s"
	else
		reason="exit ${status}: $(tr -s '[:space:]' ' ' <"${remote_work}/${step}.err" | cut -c 1-300)"
	fi
	remote_fail 1 "reading ${step} from ${remote_host} failed (${reason}); try checking ${1} is logged in for ${remote_host} and the change is visible to you"
}
