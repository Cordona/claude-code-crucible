#!/bin/sh
# Step 4i: one cell's main, interactive, in tmux, mode default, sonnet.
#   interactive.sh start CELL   start main in the run's repo, paste its prompt
#   interactive.sh snap CELL    append the pane to sessions/CELL/panes.txt
#   interactive.sh key CELL K   send one key (logged in keys.txt)
#   interactive.sh stop CELL    /exit, then end the tmux session
# RUN_SUFFIX names the run folder, as for run.sh. Sandbox only.
set -eu
SB=/Users/Shared/crucible-sandbox/final/real
RUN="${SB}/run${RUN_SUFFIX:-}"
c=$2 sdir="${RUN}/sessions/$2" tm="real-$2"
case $1 in
	start)
		tmux new-session -d -s "${tm}" -x 220 -y 60 -c "${RUN}/repo" \
			"env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PATH='/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/evidence/final/stub-bin:${PATH}' claude --permission-mode default --settings '${sdir}/flag-settings.json' --model sonnet"
		tmux display-message -p -t "${tm}" '#{pane_pid}' >"${sdir}/tmux.pid"
		: >"${sdir}/keys.txt" ;;
	paste)
		tmux load-buffer -b "${tm}" "${sdir}/main-prompt.txt"
		tmux paste-buffer -b "${tm}" -t "${tm}"
		sleep 1
		tmux send-keys -t "${tm}" Enter
		printf '%s paste main-prompt.txt, Enter\n' "$(date +%T)" >>"${sdir}/keys.txt" ;;
	snap) { printf '\n===== %s\n' "$(date +%T)"; tmux capture-pane -p -t "${tm}"; } >>"${sdir}/panes.txt"; tmux capture-pane -p -t "${tm}" | tail -n 25 ;;
	key) tmux send-keys -t "${tm}" "$3"; printf '%s key %s\n' "$(date +%T)" "$3" >>"${sdir}/keys.txt" ;;
	stop) tmux send-keys -t "${tm}" '/exit' Enter; sleep 3; tmux kill-session -t "${tm}" 2>/dev/null || true ;;
esac
