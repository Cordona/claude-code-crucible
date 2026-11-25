#!/usr/bin/env sh
# Pushes one live tree's branch tip to a remote under the same name, on the
# human's recorded yes, and records it as push.made.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gp_ function exits on its own failure; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh push-tree.sh --effort FOLDER --name NAME --remote REMOTE
                       [--timeout SECONDS]

Pushes the exact tip of live tree NAME's branch to REMOTE under the same
name, in any effort state, when the human wants a tree's work there.

Options:
  --effort FOLDER    the effort's folder, absolute
  --name NAME        a live tree of the effort
  --remote REMOTE    a remote of the tree's repository (push-remote.sh)
  --timeout SECONDS  limit on the whole push, 1 to 600; default 60
Requires:  the human's yes at a yes gate, record push-tree, subject
           NAME:<full tip sha now>; one yes pushes once
Reads:     GIT_SSH_COMMAND or core.sshCommand; ssh runs without prompts
Writes:    REMOTE's branch, fast-forward or by lease; push.made
Stdout:    {name, remote, branch, commit, lease|null, event}
Exit:
  0  pushed and recorded
  2  refused, nothing changed; the reason is on stderr
  4  a tool failed, nothing pushed; or pushed, push.made not written: rerun
  5  the push failed, was rejected or timed out; nothing changed
  6  pushed, but the events lock stayed held: rerun
USAGE
}

# A tree's name: lowercase words joined by dashes.
NAME_RULE='^[a-z][a-z0-9]*(-[a-z0-9]+)*$'
DEFAULT_TIMEOUT=60
MAX_TIMEOUT=600
# ssh gives up on a host that doesn't answer inside the push's limit, so the
# push fails with ssh's own reason.
SSH_CONNECT_TIMEOUT=10

gp_prog='push-tree.sh'
. "$(dirname -- "$0")/../lib/git-push.sh"
effort='' name='' remote='' timeout=${DEFAULT_TIMEOUT}
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --name | --remote | --timeout)
			[ $# -ge 2 ] || gp_refuse "$1 needs a value"
			case $1 in
				--effort) effort=$2 ;; --name) name=$2 ;;
				--remote) remote=$2 ;; --timeout) timeout=$2 ;; *) ;;
			esac
			shift 2 ;;
		*) gp_refuse "unknown argument $(gp_printable "$1"); try --help" ;;
	esac
done
gp_find_self "$0"
gp_find_neighbours
gp_check_effort "${effort}"
printf '%s' "${name}" | grep -Eq "${NAME_RULE}" \
	|| gp_refuse "--name $(gp_printable "${name}") must be lowercase words joined by dashes"
# A whole number with no leading zero, so the shell never reads it as octal.
case ${timeout} in
	'' | 0* | *[!0-9]* | ????*) gp_refuse "--timeout $(gp_printable "${timeout}") must be a whole number of seconds from 1 to ${MAX_TIMEOUT}" ;;
	*) [ "${timeout}" -le "${MAX_TIMEOUT}" ] || gp_refuse "--timeout ${timeout} is over ${MAX_TIMEOUT}" ;;
esac
gp_make_work

tree=$(sh "${gp_trees}" --effort "${gp_effort}" --name "${name}") || exit $?
tree=$(printf '%s' "${tree}" | jq -c 'first // empty')
[ -n "${tree}" ] || gp_refuse "the effort has no live tree named ${name}"
branch=$(printf '%s' "${tree}" | jq -r '.branch')
repo=$(printf '%s' "${tree}" | jq -r '.repo')
cut_seq=$(printf '%s' "${tree}" | jq -r '.seq')
shown_branch=$(gp_printable "${branch}")
# Main, master, develop and release/* only move through a reviewed merge.
case ${branch} in
	main | master | develop | release/*) gp_refuse "refusing to push the protected branch ${shown_branch}" ;;
	crucible/?*) ;;
	*) gp_refuse "tree ${name}'s branch ${shown_branch} is not a crucible/ branch" ;;
esac
git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1 || gp_refuse "tree ${name}'s repository $(gp_printable "${repo}") is not there"
tip=$(git -C "${repo}" rev-parse --verify --quiet "refs/heads/${branch}^{commit}") \
	|| gp_refuse "tree ${name}'s branch ${shown_branch} is gone"
sh "${gp_scripts}/main/push-remote.sh" --repo "${repo}" --remote "${remote}" >/dev/null || exit $?

sh "${gp_core_reader}" --effort "${gp_effort}" >"${gp_work}/events" || gp_fail 'events-read.sh failed reading the effort'
# The lease: the commit of this tree's last push to this remote, when the
# tree moved after it; only events since the tree's cut count.
lease=$(jq -r --arg n "${name}" --arg r "${remote}" --argjson cut "${cut_seq}" '
	[.[] | select(.seq > $cut and .body.name == $n)] as $mine
	| ([$mine[] | select(.type == "push.made" and .body.remote == $r)] | last) as $pushed
	| ([$mine[] | select(.type == "worktree.moved")] | last) as $moved
	| if $pushed != null and $moved != null and $moved.seq > $pushed.seq then $pushed.body.commit else "" end' "${gp_work}/events")

subject="${name}:${tip}"
said=$(sh "${gp_core_answer}" --effort "${gp_effort}" --record push-tree --subject "${subject}" 2>/dev/null) \
	|| gp_refuse "pushing tree ${name} needs the human's recorded yes (record push-tree, subject ${subject})"
answer=${said#ACCEPTED: }
used=$(jq --argjson a "${answer}" '[.[] | select(.type == "push.made" and .body.answer == $a)] | length' "${gp_work}/events")
[ "${used}" -eq 0 ] || gp_refuse "the human's yes ${answer} already pushed; ask again for ${subject}"

ssh_command=${GIT_SSH_COMMAND:-$(git -C "${repo}" config core.sshCommand 2>/dev/null || :)}
GIT_SSH_COMMAND="${ssh_command:-ssh} -o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
export GIT_SSH_COMMAND
# The exact tip the human said yes to is pushed, under the branch's full
# name, so a commit made since or a tag of the same name can't stand in.
set -- git -C "${repo}" -c core.hooksPath=/dev/null push --quiet
[ -z "${lease}" ] || set -- "$@" "--force-with-lease=refs/heads/${branch}:${lease}"
gp_run_timed "${timeout}" "$@" -- "${remote}" "${tip}:refs/heads/${branch}"

shown_remote=$(gp_printable "${remote}")
if [ "${gp_rc}" -ne 0 ]; then
	[ "${gp_timed_out}" = no ] || { printf '%s: the push of %s to %s timed out after %s s; it was stopped\n' "${gp_prog}" "${shown_branch}" "${shown_remote}" "${timeout}" >&2; exit 5; }
	if [ -n "${lease}" ] && grep -q -- 'stale info' "${gp_work}/stderr"; then
		printf '%s: the push of %s to %s was rejected: the remote branch is no longer at %s, this tree'"'"'s last push; nothing was forced\n' "${gp_prog}" "${shown_branch}" "${shown_remote}" "${lease}" >&2
		exit 5
	fi
	if grep -Eq -- 'non-fast-forward|fetch first|behind' "${gp_work}/stderr"; then
		printf '%s: the push of %s to %s was rejected: the remote branch holds commits this tree lacks; nothing was forced\n' "${gp_prog}" "${shown_branch}" "${shown_remote}" >&2
		exit 5
	fi
	first_line=$(sed '/^[[:space:]]*$/d' "${gp_work}/stderr" | head -n 1)
	printf '%s: the push of %s to %s failed (exit %s): %s\n' "${gp_prog}" "${shown_branch}" "${shown_remote}" "${gp_rc}" "$(gp_printable "${first_line:-no message}")" >&2
	exit 5
fi

jq -n --arg name "${name}" --arg remote "${remote}" --arg commit "${tip}" --argjson answer "${answer}" \
	'{name: $name, remote: $remote, commit: $commit, answer: $answer}' >"${gp_work}/body"
# The tree can be dropped while its push runs; push.made names a live tree
# only, so git-worktree is asked again just before the write.
write_rc=0
live_now=$(sh "${gp_trees}" --effort "${gp_effort}" --name "${name}" 2>/dev/null) || live_now=''
if printf '%s' "${live_now}" | jq -e 'length == 1' >/dev/null 2>&1; then
	event=$(sh "${gp_core_writer}" --effort "${gp_effort}" --type push.made --by "${gp_prog}" --body-file "${gp_work}/body") || write_rc=$?
else
	printf '%s: tree %s is no longer live; push.made names a live tree only\n' "${gp_prog}" "${name}" >&2
	write_rc=4
fi
if [ "${write_rc}" -ne 0 ]; then
	printf '%s: %s is pushed to %s at %s, but push.made was not written\n' "${gp_prog}" "${shown_branch}" "${shown_remote}" "${tip}" >&2
	[ "${write_rc}" -eq 6 ] || exit 4
	exit 6
fi
jq -nc --arg name "${name}" --arg remote "${remote}" --arg branch "${branch}" --arg commit "${tip}" \
	--arg lease "${lease}" --arg event "${event}" \
	'{name: $name, remote: $remote, branch: $branch, commit: $commit,
	  lease: (if $lease == "" then null else $lease end), event: $event}'
