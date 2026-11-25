#!/bin/sh
# Spike: plays the human of a live Stage C run in tmux. Makes a fresh run
# folder (the trees, the effort, the lab's settings, main.md as CLAUDE.md),
# starts main, sends the run's first message, and then sends each next line
# of answers.txt only when it is due:
# - an answer, only while a question or a card's offer is on screen;
# - a request (or a reopening), only while main is idle and the effort has as
#   many events as the dry run had when the human spoke.
# Every send is logged with its time and the screen's tail. It sends nothing
# else. The author's pushes are done at their dry-run event count too.
# usage: tmux-drive.sh RUN [N] [--limit SECONDS]
# Needs evidence/dry/RUN/driver.log (sh lab/driver.sh RUN) for the order.
set -eu
C=$(cd "$(dirname "$0")" && pwd); LAB=$(dirname "$C"); SPIKE=$(dirname "$LAB")
SANDBOX=/Users/Shared/crucible-sandbox/event-jobs
RUN=${1:?usage: tmux-drive.sh RUN [N] [--limit SECONDS]}; shift
N=1; LIMIT=3600
while [ $# -gt 0 ]; do
	case "$1" in --limit) LIMIT=$2; shift 2 ;; *) N=$1; shift ;; esac
done
RUNDIR=$C/runs/$RUN; DRY=$SPIKE/evidence/dry/$RUN/driver.log
[ -f "$RUNDIR/plan" ] && [ -f "$DRY" ] || { echo "tmux-drive: no run $RUN or no dry run of it" >&2; exit 1; }
D=$SANDBOX/runs/$RUN-$N
[ ! -e "$D" ] || { echo "tmux-drive: $D exists; give another N" >&2; exit 1; }
TMUX_S=ej-$RUN-$N
ASK_RE=${ASK_RE:-'Enter to select|to navigate'}
BUSY_RE=${BUSY_RE:-'esc to interrupt'}
READY_RE=${READY_RE:-'bypass permissions on'}

mkdir -p "$D/effort/events" "$D/effort/acts"
EFFORT=$D/effort; export EFFORT
cp "$RUNDIR"/acts/*.json "$EFFORT/acts/" 2>/dev/null || true
LOG=$D/sends.log; : > "$LOG"; NOTE=$D/drive.log; : > "$NOTE"
note() { printf '%s %s\n' "$(date +%s)" "$*" >> "$NOTE"; }
grep -q '"hang": true' "$RUNDIR"/acts/*.json 2>/dev/null && note "an act asks a stand-in to hang; the lab agents can't, so that step will not happen live"

# --- the run folder, as the plan sets it up before main starts ---------------
first=''
kinds=shell
repo() {
	mkdir -p "$D/$1"; git -C "$D/$1" init -q
	printf 'echo a\n' > "$D/$1/a.sh"; printf 'echo b\n' > "$D/$1/b.sh"
	git -C "$D/$1" add -A; git -C "$D/$1" -c user.name=lab -c user.email=lab@lab commit -qm first
	printf '.claude/\nCLAUDE.md\n' >> "$D/$1/.git/info/exclude"
	[ -n "$first" ] || first=$1
}
commit() {
	printf 'echo %s\n' "$2" >> "$D/$1/$2"
	git -C "$D/$1" add -A; git -C "$D/$1" -c user.name=author -c user.email=a@a commit -qm "$2"
}
while IFS= read -r d <&3; do
	set -- $d
	case "${1:-}" in
	kinds) kinds=$2 ;;
	repo) repo "$2" ;;
	commit) commit "$2" "$3" ;;
	pr-open) sh "$LAB/remote.sh" --effort "$EFFORT" --session drive --open --pr "$2" --tree "$D/$3" \
		--base "$(git -C "$D/$3" rev-list --max-parents=0 HEAD)" --head "$(git -C "$D/$3" rev-parse HEAD)" \
		${4:+--threads "$(jq -c . "$RUNDIR/$4")"} >/dev/null ;;
	push) printf '%s\n' "$*" >> "$D/pushes" ;;
	esac
done 3< "$RUNDIR/plan"
CWD=$D/$first
mkdir -p "$CWD/.claude/agents" "$CWD/.claude/skills/crucible-gate"
cp "$LAB"/agents/*.md "$CWD/.claude/agents/"
cp "$LAB/real/crucible-gate/SKILL.md" "$CWD/.claude/skills/crucible-gate/SKILL.md"
sed "s|__LAB__|$LAB|g; s|__EFFORT__|$EFFORT|g" "$C/main.md" > "$CWD/CLAUDE.md"
sed "s|__LAB__|$LAB|g; s|__EFFORT__|$EFFORT|g" "$C/settings.json" |
	jq --arg k "$kinds" '.env.LAB_KINDS = $k' > "$CWD/.claude/settings.json"
shasum "$CWD/CLAUDE.md" | cut -d' ' -f1 > "$D/main-md.sha1"

# --- the human's lines, in the dry run's order, with what each waits for ------
# each line: kind, event count, the gate an answer is for (its card's record,
# from the dry run's last "main: card" line), words
awk '/^main: card /{c=$3; sub(/\.md$/, "", c); r=c
		n=split("build test-plan test review fix-choice end-card plan-gate replies comments", k, " ")
		for (i = 1; i <= n; i++) if (index(c, k[i] "-") == 1) { r = k[i]; break } }
	/^human \(/{match($0, /^human \([a-z ]*\)/); kind=substr($0, 8, RLENGTH-8)
		rest=substr($0, RLENGTH+3); at=rest; sub(/:.*/, "", at); w=rest; sub(/^[0-9]*: /, "", w)
		printf "%s\t%s\t%s\t%s\n", kind, at, (kind == "answer" ? r : "-"), w }
	/^remote @/{at=$2; sub(/^@/, "", at); sub(/:$/, "", at); printf "push\t%s\t-\t\n", at}' "$DRY" > "$D/todo"
[ "$(grep -vc '^push' "$D/todo")" -eq "$(grep -c . "$RUNDIR/answers.txt")" ] || { echo "tmux-drive: the dry log and answers.txt disagree" >&2; exit 1; }

# --- tmux ----------------------------------------------------------------------
start_main() { # extra claude arguments
	tmux new-session -d -s "$TMUX_S" -x 200 -y 50 -c "$CWD" \
		"env CLAUDE_CONFIG_DIR=$SANDBOX/cfg claude --permission-mode bypassPermissions $*"
	note "main started $*"
	# a new run folder asks once whether to trust it: that is the harness's
	# setup, not the human's work, so it is accepted here and logged as such
	# (and, in bypass mode, once whether to accept that mode): both are accepted
	# here, before any human line, until the prompt shows neither
	# main is ready only once its input box shows the permission-mode footer
	# and no setup prompt is up
	w=0
	while [ "$w" -lt 90 ]; do
		s=$(tmux capture-pane -p -t "$TMUX_S" 2>/dev/null || true)
		if printf '%s' "$s" | grep -Eq 'Yes, I trust this folder|Yes, I accept'; then
			tmux send-keys -t "$TMUX_S" Down; sleep 0.5; tmux send-keys -t "$TMUX_S" Enter
			note "setup prompt accepted: $(printf '%s' "$s" | grep -Eo 'Yes, I trust this folder|Yes, I accept' | head -1)"
			sleep 3
		elif printf '%s' "$s" | grep -Eq "$READY_RE"; then
			sleep 2
			s=$(tmux capture-pane -p -t "$TMUX_S" 2>/dev/null || true)
			printf '%s' "$s" | grep -Eq 'Yes, I trust this folder|Yes, I accept' || { note "main ready"; return 0; }
		else
			sleep 1
		fi
		w=$((w + 1))
	done
	note "main never showed its input box"; exit 1
}
screen() { tmux capture-pane -p -t "$TMUX_S" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -25; }
events() { ls "$EFFORT/events" | grep -c '\.json$' || true; }
idle() { # the screen shows no work and holds still for three seconds; a
	# background agent's ticking timer is not a change
	a=$(screen | tr -d '0-9'); printf '%s' "$a" | grep -Eq "$BUSY_RE" && return 1
	sleep 3; b=$(screen | tr -d '0-9'); [ "$a" = "$b" ] && ! printf '%s' "$b" | grep -Eq "$BUSY_RE"
}
asking() { # the question dialog is up, and main is not working
	s=$(screen); printf '%s' "$s" | grep -Eq "$ASK_RE" && ! printf '%s' "$s" | grep -Eq "$BUSY_RE"
}
on_screen_question() { screen | grep -Eq "$ASK_RE"; }
# the gate being asked now: the core gate's newest record, a card marked
# shown (owed/) or the question it is waiting to record (answers/)
shown_gate() {
	f=$(ls -t "$SANDBOX"/cfg/cache/crucible-gate/*/owed/*.json "$SANDBOX"/cfg/cache/crucible-gate/*/answers/*.json 2>/dev/null | head -1)
	[ -n "$f" ] && jq -r 'if (.record | type) == "object" then (select(.status == "shown") | .record.record) else (.record // empty) end' "$f" 2>/dev/null
}
send() { # KIND WORDS KEYS...: types the keys, logs the send
	kind=$1 words=$2; shift 2
	tail=$(screen)
	for k in "$@"; do
		case "$k" in Enter) tmux send-keys -t "$TMUX_S" Enter ;; *) tmux send-keys -t "$TMUX_S" -l "$k" ;; esac
	done
	jq -nc --argjson t "$(date +%s)" --arg k "$kind" --arg w "$words" --arg tail "$tail" --argjson keys "$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]')" \
		'{t: $t, kind: $k, words: $w, keys: $keys, screen_tail: $tail}' >> "$LOG"
}
answer() { # WORDS: picks the recommended option for a yes, else types the words as the human's own
	case "$1" in
	[Yy]es*) send answer "$1" Enter ;;
	*) own=$(screen | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\. Type something.*/\1/p' | tail -1)
		if [ -n "$own" ]; then send answer "$1" "$own" "$1" Enter; else send answer "$1" "$1" Enter; fi ;;
	esac
}
done_now() { # all lines sent, nothing owed or waiting, main idle
	[ ! -s "$D/todo" ] || return 1
	[ "$(events)" -ge "$DRY_EVENTS" ] || return 1
	[ -z "$(sh "$LAB/owes.sh" --effort "$EFFORT" | jq -c 'select(.owed != null or .waiting != [])')" ] && idle
}

DRY_EVENTS=$(ls "$(dirname "$DRY")/events" | grep -c '\.json$')
start_main
t0=$(date +%s)
until idle; do sleep 2; [ $(($(date +%s) - t0)) -lt 120 ] || { note "main never became idle"; exit 1; }; done
IFS='	' read -r kind at gate words < "$D/todo"; sed -i '' 1d "$D/todo"
send "$kind" "$words" "$words" Enter

result=limit
STALL=${STALL:-300}
seen=$(events); moved=$(date +%s)
while [ $(($(date +%s) - t0)) -lt "$LIMIT" ]; do
	if done_now; then result="done"; break; fi
	# no new event and no send for STALL seconds while main sits idle: stalled
	now_ev=$(events)
	if [ "$now_ev" != "$seen" ] || [ "$(wc -l < "$LOG")" != "${sent:-0}" ]; then
		seen=$now_ev; sent=$(wc -l < "$LOG"); moved=$(date +%s)
	elif [ $(($(date +%s) - moved)) -ge "$STALL" ] && idle; then
		result=stalled; note "stalled: no event and no send for ${STALL}s, main idle"; break
	fi
	[ -s "$D/todo" ] || { sleep 5; continue; }
	IFS='	' read -r kind at gate words < "$D/todo"
	case "$kind" in
	# an answer goes only to the gate it is for
	answer) [ "$(events)" -ge "$at" ] && asking && [ "$(shown_gate)" = "$gate" ] || { sleep 3; continue; } ;;
	# a request or a push only at an idle prompt with no question open
	*) [ "$(events)" -ge "$at" ] && idle && ! on_screen_question || { sleep 3; continue; } ;;
	esac
	sed -i '' 1d "$D/todo"
	case "$kind" in
	answer) answer "$words" ;;
	push) set -- $(sed -n 1p "$D/pushes"); sed -i '' 1d "$D/pushes"
		commit "$3" "$4"
		sh "$LAB/remote.sh" --effort "$EFFORT" --session drive --push --pr "$2" --head "$(git -C "$D/$3" rev-parse HEAD)" \
			--replies "$(jq -c . "$RUNDIR/$5")" >/dev/null
		note "the author pushed to $2" ;;
	reopen) tmux kill-session -t "$TMUX_S"; note "session closed"
		start_main --continue
		until idle; do sleep 2; done
		send reopen "$words" "$words" Enter ;;
	*) send "$kind" "$words" "$words" Enter ;;
	esac
done
note "end: $result"
tmux capture-pane -p -S - -t "$TMUX_S" > "$D/screen.txt" 2>/dev/null || true
tmux capture-pane -p -t "$TMUX_S" -S -3000 > "$D/screen-final.txt" 2>/dev/null || true
tmux kill-session -t "$TMUX_S" 2>/dev/null || true
echo "$D: $result"
[ "$result" = "done" ]
