#!/bin/sh
# Live run of the remote kinds with the real reviewer: a foreign review and an
# external review of one synthetic GitLab merge request, then the external
# review again on the same, unmoved review. Run after live.sh setup.
#   [SEED=1] remotes-live.sh setup    the merge request (SEED: a planted test defect outside the change): a change pushed to a local
#                            bare "host" the repo reaches through insteadOf,
#                            and a glab stand-in answering its review
#   remotes-live.sh start    the session in tmux (jobs-live), the stand-in
#                            first on PATH, auto mode
#   remotes-live.sh collect  the evidence, to out-remotes/
set -eu
E=$(cd -- "$(dirname -- "$0")" && pwd)
L=/Users/Shared/crucible-sandbox/jobs-live
RUN="${L}/run"
export CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg
export CRUCIBLE_HOME="${RUN}/space" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
K="${CLAUDE_CONFIG_DIR}/skills"
ER="${K}/crucible-events/scripts/internal/events-read.sh"
HOST=gitlab.example.test PROJECT=acme/greet

setup() {
	. "${RUN}/vars"
	# SEED=1: a plain defect in a test outside the change, beside the code it
	# changes: the test can never fail. A reviewer drawn to it must say how it
	# relates to the change, or the report is refused.
	if [ "${SEED:-}" = 1 ]; then
		printf '#!/bin/sh\nset -eu\nout=$(sh "$(dirname "$0")/../bin/greet.sh" ada) || :\n[ -n "${out}" ] || [ -z "${out}" ]\n' >"${repo}/tests/greet_test.sh"
		git -c user.name=Fixture -c user.email=fixture@example.test -c commit.gpgsign=false -C "${repo}" commit -qam 'Simplify the greeting test'
	fi
	base=$(git -C "${repo}" rev-parse main)
	# The change: --shout, with a slip a reviewer should find (the flag
	# after the name is taken as the name).
	git -C "${repo}" worktree add -q -b feat/shout "${RUN}/mr" main
	printf '#!/bin/sh\n# Prints a greeting for the name given; --shout first prints it in capitals.\nset -eu\nshout=no\n[ "${1-}" = --shout ] && { shout=yes; shift; }\nname=${1:-world}\nline=$(printf '"'"'hello %%s'"'"' "${name}")\n[ "${shout}" = no ] || line=$(printf '"'"'%%s'"'"' "${line}" | tr a-z A-Z)\necho "${line}"\n' >"${RUN}/mr/bin/greet.sh"
	git -c user.name=Other -c user.email=other@example.test -c commit.gpgsign=false -C "${RUN}/mr" commit -qam 'Add --shout'
	head=$(git -C "${RUN}/mr" rev-parse HEAD)
	git -C "${repo}" worktree remove --force "${RUN}/mr"
	git init -q --bare "${RUN}/host.git"
	git -C "${repo}" push -q "${RUN}/host.git" main "${head}:refs/merge-requests/42/head"
	git -C "${repo}" branch -D -q feat/shout
	git -C "${repo}" remote add origin "https://${HOST}/${PROJECT}.git"
	git -C "${repo}" config "url.${RUN}/host.git.insteadOf" "https://${HOST}/${PROJECT}.git"
	# The host's answers, in the shape the live reads showed.
	mkdir -p "${RUN}/bin" "${RUN}/gitlab"
	jq -n --arg b "${base}" --arg h "${head}" '{iid: 42, project_id: 7, title: "Add --shout", description: "Adds a --shout flag that prints the greeting in capitals.",
		state: "opened", author: {username: "fixer"}, target_branch: "main", sha: $h, diff_refs: {base_sha: $b, head_sha: $h, start_sha: $b}}' >"${RUN}/gitlab/mr.json"
	jq -n --arg b "${base}" --arg h "${head}" '[{id: 1, head_commit_sha: $h, base_commit_sha: $b, start_commit_sha: $b, created_at: "2026-11-27T09:00:00.000Z"}]' >"${RUN}/gitlab/versions.json"
	jq -n --arg h "${head}" '[
	 {id: "d-bot", individual_note: true, notes: [{id: 101, type: null, system: false, resolvable: false, resolved: null, author: {username: "review-bot"},
	   created_at: "2026-11-27T09:10:00.000Z", updated_at: "2026-11-27T09:10:00.000Z",
	   body: "AI review\n\n1. `bin/greet.sh`: `greet.sh ada --shout` prints hello ada: the flag after the name is ignored without a word.\n2. `bin/greet.sh:8`: use `printf` instead of `echo` for the line, as the rest of the script does.\n3. `bin/greet.sh:8`: `tr a-z A-Z` misses non-ASCII letters."}]},
	 {id: "d-reply", individual_note: true, notes: [{id: 102, type: null, system: false, resolvable: false, resolved: null, author: {username: "fixer"},
	   created_at: "2026-11-27T09:30:00.000Z", updated_at: "2026-11-27T09:30:00.000Z",
	   body: "1. As specified: --shout goes before the name. 2. Will change. 3. Names are ASCII here."}]},
	 {id: "d-line", individual_note: false, notes: [
	   {id: 103, type: "DiffNote", system: false, resolvable: true, resolved: false, author: {username: "human-rev"},
	    created_at: "2026-11-27T09:20:00.000Z", updated_at: "2026-11-27T09:20:00.000Z",
	    position: {head_sha: $h, new_path: "bin/greet.sh", old_path: "bin/greet.sh", position_type: "text", new_line: 5, old_line: null},
	    body: "What happens with `greet.sh --shout` and no name? Please check it greets the world in capitals."},
	   {id: 104, type: "DiffNote", system: false, resolvable: true, resolved: false, author: {username: "fixer"},
	    created_at: "2026-11-27T09:35:00.000Z", updated_at: "2026-11-27T09:35:00.000Z",
	    position: {head_sha: $h, new_path: "bin/greet.sh", old_path: "bin/greet.sh", position_type: "text", new_line: 5, old_line: null},
	    body: "It does: name falls back to world after the shift."}]},
	 {id: "d-done", individual_note: false, notes: [{id: 105, type: "DiscussionNote", system: false, resolvable: true, resolved: true, author: {username: "human-rev"},
	   created_at: "2026-11-27T09:25:00.000Z", updated_at: "2026-11-27T09:40:00.000Z", body: "Typo in the commit message."}]},
	 {id: "d-sys", individual_note: true, notes: [{id: 106, type: null, system: true, resolvable: false, resolved: null, author: {username: "fixer"},
	   created_at: "2026-11-27T09:00:01.000Z", updated_at: "2026-11-27T09:00:01.000Z", body: "added 1 commit"}]}]' >"${RUN}/gitlab/discussions.json"
	cat >"${RUN}/bin/glab" <<EOF
#!/bin/sh
# A stand-in for glab, for the one synthetic merge request of this run.
set -eu
printf '%s\n' "\$*" >>"${RUN}/glab.log"
case "\$*" in
	*"/discussions"*) cat "${RUN}/gitlab/discussions.json" ;;
	*"/versions"*) cat "${RUN}/gitlab/versions.json" ;;
	*"/merge_requests/42"*) cat "${RUN}/gitlab/mr.json" ;;
	*) echo "glab: 404 Not Found" >&2; exit 1 ;;
esac
EOF
	chmod +x "${RUN}/bin/glab"
	printf 'mr=https://%s/%s/-/merge_requests/42\nmr_base=%s\nmr_head=%s\n' "${HOST}" "${PROJECT}" "${base}" "${head}" >>"${RUN}/vars"
	cat "${RUN}/vars"
}

start() {
	. "${RUN}/vars"
	tmux kill-session -t jobs-live 2>/dev/null || :
	tmux new-session -d -s jobs-live -x 220 -y 50 -c "${repo}" "env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT PATH='${RUN}/bin:${PATH}' CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR} CRUCIBLE_HOME=${CRUCIBLE_HOME} GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 claude --model claude-opus-5-5 --permission-mode auto; sleep 3000"
}

collect() {
	. "${RUN}/vars"
	o="${E}/${OUT:-out-remotes}"
	rm -rf -- "${o}"; mkdir -p "${o}/reports"
	sh "${ER}" --effort "${effort}" | jq '[.[] | {seq, type, by, body}]' | sed "s|${L}|<L>|g" >"${o}/events.json"
	for d in remote-change remote-review foreign-review external-review; do
		[ ! -d "${effort}/reports/${d}" ] || cp -R "${effort}/reports/${d}" "${o}/reports/"
	done
	cp "${RUN}/glab.log" "${o}/glab.log" 2>/dev/null || :
	ls "${CLAUDE_CONFIG_DIR}/agents" >"${o}/agent-files.txt"
}

case ${1-} in setup) setup ;; start) start ;; collect) collect ;; *) echo "usage: remotes-live.sh setup|start|collect" >&2; exit 2 ;; esac
