#!/bin/sh
# Spike: the dry run of a Stage C run, with no model. It plays main and the
# agents: feeds the real lab hooks and the core gate's hooks the input they
# would get, and calls the scripts a correct main would, in order. The human's
# words come from the run's answers.txt, one line per decision; the agents do
# what their acts say. Writes evidence/dry/<run>/: expected.json (the event
# sequence per root, with no seq or id), checks.json, driver.log, the events
# and the hook log.
# usage: driver.sh RUN... | all       (RUN is a folder name under c/runs)
# Directives in c/runs/<run>/plan, one per line:
#   kinds K,K            the review kinds main proposes at a review gate
#   repo NAME            a git repo with a first commit
#   commit NAME FILE     the author commits a change to FILE in NAME
#   build NAME | test NAME | plan NAME     the human asks for it (one answer)
#   pr-open ID NAME [THREADS-FILE]         the fake remote gets a PR
#   fetch ID | request ID                  the human asks main to take it up
#   push ID NAME FILE REPLIES-FILE         the author pushes a change
#   close-session        the session closes and the human reopens it (one answer)
#   close-at-owed STEP   the same, when STEP is next held
#   settle               main and the agents run until nothing is left
#   expect JQ            a check over the run's events, true when it holds
#   expect-log REGEX     a check that the driver log has a matching line
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); export LAB
SPIKE=$(dirname "$LAB")
GATE=$LAB/real/crucible-gate

log() { printf '%s\n' "$*" >> "$OUT/driver.log"; }
# the number of events so far: a live run waits for as many before a request
at_events() { ls "$EFFORT/events" 2>/dev/null | grep -c '\.json$' || true; }
fail() { log "FAIL: $*"; echo "driver: $RUN: $*" >&2; FAILED=1; }

# sets words to the human's next line; KIND says what it is to a live run:
# answer (to a question on screen), request, or reopen; a request while a
# loop is live is marked so
next_answer() {
	ANSWER_N=$((ANSWER_N + 1))
	words=$(sed -n "${ANSWER_N}p" "$RUNDIR/answers.txt")
	[ -n "$words" ] || { fail "answers.txt has no line $ANSWER_N"; STUCK=1; }
	kind=${1:-request}
	[ "$kind" != request ] || ! sh "$LAB/owes.sh" --effort "$EFFORT" | jq -e 'select(.loop != null)' >/dev/null 2>&1 || kind="request in loop"
	log "human ($kind) @$(at_events): $words"
}

hook() { # SCRIPT JSON: the hook's stdout
	printf '%s' "$2" | sh "$1" 2>>"$OUT/driver.log" || true
}
hook_in() { # JQ-ARGS... FILTER: a hook input with the running session
	jq -nc --arg s "$SESSION" "$@"
}

# --- agents ------------------------------------------------------------------

agent_set() { # ID TYPE STATE
	grep -v "^$1 " "$W/agents" > "$W/agents.tmp" || true
	echo "$1 $2 $3" >> "$W/agents.tmp"; mv "$W/agents.tmp" "$W/agents"
}
agent_type() { awk -v a="$1" '$1 == a {print $2}' "$W/agents"; }
idle_agents() { awk '$3 == "idle" {print $1}' "$W/agents"; }

start_call() { # one printed call
	call=$(printf '%s' "$1" | jq -r .call)
	TOOL_N=$((TOOL_N + 1)); tu="tu-$TOOL_N"
	if [ "$call" = Agent ]; then
		type=$(printf '%s' "$1" | jq -r .subagent_type); prompt=$(printf '%s' "$1" | jq -r .prompt)
		AGENT_N=$((AGENT_N + 1)); aid=$(printf 'ag%02d%s' "$AGENT_N" "$SESSION_N")
		pre=$(hook "$LAB/pre-agent.sh" "$(hook_in --arg t "$type" --arg p "$prompt" --arg u "$tu" \
			'{session_id: $s, tool_name: "Agent", tool_use_id: $u, tool_input: {subagent_type: $t, prompt: $p, run_in_background: true}}')")
		if printf '%s' "$pre" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
			log "refused by pre-agent: $(printf '%s' "$pre" | jq -r .hookSpecificOutput.permissionDecisionReason)"; return
		fi
		hook "$LAB/post-agent.sh" "$(hook_in --arg t "$type" --arg p "$prompt" --arg u "$tu" --arg a "$aid" \
			'{session_id: $s, tool_name: "Agent", tool_use_id: $u, tool_input: {subagent_type: $t, prompt: $p, run_in_background: true}, tool_response: {agentId: $a}}')" >/dev/null
		log "main: Agent $type -> $aid"
	else
		aid=$(printf '%s' "$1" | jq -r .to); msg=$(printf '%s' "$1" | jq -r .message); type=$(agent_type "$aid")
		pre=$(hook "$LAB/pre-send.sh" "$(hook_in --arg a "$aid" --arg m "$msg" --arg u "$tu" \
			'{session_id: $s, tool_name: "SendMessage", tool_use_id: $u, tool_input: {to: $a, message: $m}}')")
		if printf '%s' "$pre" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
			log "refused by pre-send: $(printf '%s' "$pre" | jq -r .hookSpecificOutput.permissionDecisionReason)"; return
		fi
		hook "$LAB/post-send.sh" "$(hook_in --arg a "$aid" --arg m "$msg" --arg u "$tu" \
			'{session_id: $s, tool_name: "SendMessage", tool_use_id: $u, tool_input: {to: $a, message: $m}, tool_response: {success: true}}')" >/dev/null
		log "main: SendMessage -> $aid"
	fi
	agent_set "$aid" "$type" busy
	echo "$aid" >> "$W/pending"
}

agent_tool() { # AID TYPE TOOL PATH: the scope hook's answer, "deny: reason" or ""
	out=$(hook "$LAB/scope.sh" "$(hook_in --arg a "$1" --arg t "$2" --arg tool "$3" --arg f "$4" \
		'{session_id: $s, tool_name: $tool, agent_id: $a, agent_type: $t, tool_input: {file_path: $f}}')")
	printf '%s' "$out" | jq -r 'select(.hookSpecificOutput.permissionDecision == "deny") | "deny: " + .hookSpecificOutput.permissionDecisionReason' 2>/dev/null || true
}
agent_write() { # AID TYPE PATH CONTENT
	d=$(agent_tool "$1" "$2" Write "$3")
	if [ -n "$d" ]; then log "agent $1: write $3 $d"; return; fi
	mkdir -p "$(dirname "$3")"; printf '%s' "$4" > "$3"
}
agent_stop() { # AID TYPE: the stop hook's block reason, or ""
	hook "$LAB/agent-stop.sh" "$(hook_in --arg a "$1" --arg t "$2" \
		'{session_id: $s, hook_event_name: "SubagentStop", agent_id: $a, agent_type: $t}')" | jq -r 'select(.decision == "block") | .reason' 2>/dev/null || true
}

run_agent() {
	aid=$1; type=$(agent_type "$aid")
	job=$(EFFORT=$EFFORT sh -c '. "$1/lib.sh"; open_job_of_agent "$2"' _ "$LAB" "$aid")
	[ -n "$job" ] || { log "agent $aid: no open job"; agent_set "$aid" "$type" idle; return; }
	je=$(EFFORT=$EFFORT sh -c '. "$1/lib.sh"; job_event "$2"' _ "$LAB" "$job")
	act=$(printf '%s' "$je" | jq -c .body.act); tree=$(printf '%s' "$je" | jq -r '.body.tree // ""'); report=$(printf '%s' "$je" | jq -r .body.report)
	if printf '%s' "$act" | jq -e '.hang == true' >/dev/null; then
		log "agent $aid: works on job $job and does not end"; echo "$aid" >> "$W/hung"; return
	fi
	if printf '%s' "$act" | jq -e '.taskstop == true' >/dev/null; then
		next_answer
		log "main: TaskStop $aid"
		hook "$LAB/post-taskstop.sh" "$(hook_in --arg a "$aid" '{session_id: $s, tool_name: "TaskStop", tool_input: {task_id: $a}, tool_response: {}}')" >/dev/null
		agent_set "$aid" "$type" gone; return
	fi
	if printf '%s' "$act" | jq -e '.stop_loop == true' >/dev/null; then
		next_answer
		main_run "sh $LAB/choose.sh --effort $EFFORT --stop --reason '$words'"
	fi
	printf '%s' "$act" | jq -r '(.files // {}) | keys[]' | while IFS= read -r f; do
		agent_write "$aid" "$type" "$tree/$f" "$(printf '%s' "$act" | jq -r --arg f "$f" '.files[$f]')"
	done
	has_report=$(printf '%s' "$act" | jq -r 'if .report == null then "no" else "yes" end')
	if printf '%s' "$act" | jq -e '.broken_first == true' >/dev/null; then agent_write "$aid" "$type" "$report" '{'
	elif [ "$has_report" = yes ]; then agent_write "$aid" "$type" "$report" "$(printf '%s' "$act" | jq -c .report)"; fi
	r=$(agent_stop "$aid" "$type")
	if [ -n "$r" ]; then
		log "agent-stop refused $aid: $r"
		[ "$has_report" = no ] || agent_write "$aid" "$type" "$report" "$(printf '%s' "$act" | jq -c .report)"
		r=$(agent_stop "$aid" "$type")
		[ -z "$r" ] || log "agent-stop refused $aid again: $r"
	fi
	state=$(EFFORT=$EFFORT sh "$LAB/view.sh" --effort "$EFFORT" | jq -r --argjson j "$job" \
		'[.[] | select(.job == $j and ((.type | endswith(".submitted")) or .type == "job.ended"))] | last
		 | if . == null then "busy" elif .type == "job.ended" then "bad" else "idle" end')
	agent_set "$aid" "$type" "$state"
	log "agent $aid: job $job ends $state"
}

# --- main --------------------------------------------------------------------

interpret() { # the human's words at a choice gate, as choose.sh options
	w=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	case "$w" in *nothing*) echo "--none"; return ;; esac
	sev=''
	for s in critical high medium low; do case "$w" in *"$s"*) sev="${sev:+$sev,}$s" ;; esac; done
	cap=1
	case "$w" in *five*|*5\ round*) cap=5 ;; *four*|*4\ round*) cap=4 ;; *three*|*3\ round*) cap=3 ;; *two*|*2\ round*) cap=2 ;; esac
	echo "--severity $sev --cap $cap"
}

main_run() { # one command line main runs, and the calls it prints
	line=$1
	case "$line" in *show-card.sh*) do_gate "$line"; return ;; esac
	case "$line" in *job-dispatch.sh*)
		case "$line" in *--delivery*) ;; *)
			for a in $(idle_agents); do
				hc=$(CLAUDE_CODE_SESSION_ID=$SESSION sh -c "$line --check --delivery hot --hot-agent $a" 2>&1 </dev/null) || true
				if printf '%s' "$hc" | jq -e '.ok == true' >/dev/null 2>&1; then
					line="$line --delivery hot --hot-agent $a"; break
				fi
				log "hot check $a: $hc"
			done ;;
		esac ;;
	esac
	log "main: ${line#sh "$LAB"/}"
	out=$(CLAUDE_CODE_SESSION_ID=$SESSION sh -c "$line" 2>>"$OUT/driver.log" </dev/null) || true
	if printf '%s' "$out" | jq -e 'select(.ok == false)' >/dev/null 2>&1; then
		log "refused: $out"
		if printf '%s' "$out" | jq -e '.refusal == "tree-busy"' >/dev/null && printf '%s' "$line" | grep -q -- '--tree'; then
			next_answer
			for t in $(ls "$W"); do
				case " $words " in *" $t "*) main_run "$(printf '%s' "$line" | sed "s|--tree [^ ]*|--tree $W/$t|")"; return ;; esac
			done
		fi
		return
	fi
	printf '%s\n' "$out" > "$W/calls.$$.$TOOL_N"
	while IFS= read -r c <&4; do
		if printf '%s' "$c" | jq -e '.call' >/dev/null 2>&1; then start_call "$c"; fi
	done 4< "$W/calls.$$.$TOOL_N"
}

do_gate() {
	line=$1; card=${line##* }
	text=$(CLAUDE_CODE_SESSION_ID=$SESSION sh -c "$line" 2>>"$OUT/driver.log" </dev/null) || { fail "show-card refused: $line"; return; }
	log "main: card $(basename "$card")"
	told=$(hook "$GATE/hooks/stop/require-card-shown.sh" "$(hook_in --arg m "$text" '{session_id: $s, hook_event_name: "Stop", last_assistant_message: $m}')")
	printf '%s' "$told" | grep -q 'Ask your question' || fail "the gate's stop hook did not say ask: $told"
	accept=$(printf '%s' "$line" | sed -n "s/.*--accept '\([^']*\)'.*/\1/p")
	question=$(head -1 "$card")
	if [ -n "$accept" ]; then
		options=$(jq -nc --arg a "$accept" '[{label: $a, description: "as the card recommends"}, {label: "Not now", description: "leave it for later"}]')
	else
		options='[{"label":"As recommended","description":"what the card recommends"},{"label":"Fix nothing","description":"leave the findings as they are"}]'
	fi
	TOOL_N=$((TOOL_N + 1)); tu="tu-$TOOL_N"
	pre=$(hook "$GATE/hooks/pre-tool-use/hold-question-until-card-shown.sh" "$(hook_in --arg u "$tu" --arg q "$question" --argjson o "$options" \
		'{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $u, tool_input: {questions: [{header: "Decision", question: $q, multiSelect: false, options: $o}]}}')")
	[ -z "$pre" ] || { fail "the question was denied: $pre"; return; }
	next_answer answer
	picked=$words
	if [ -n "$accept" ]; then case "$words" in [Yy]es*) picked=$accept ;; esac; fi
	hook "$GATE/hooks/post-tool-use/record-gate-answer.sh" "$(hook_in --arg u "$tu" --arg q "$question" --arg a "$picked" \
		'{session_id: $s, tool_name: "AskUserQuestion", tool_use_id: $u, tool_response: {answers: {($q): $a}}}')" >/dev/null
	# what follows the answer comes from next.sh, as it does for main live
	CLAUDE_CODE_SESSION_ID=$SESSION sh "$LAB/next.sh" --effort "$EFFORT" > "$W/next" </dev/null
	while IFS= read -r l <&3; do
		case "$l" in
		"owed: from the human's answer "*) t=${l#*\": }; main_run "${t%%, then *} $(interpret "$words")" </dev/null ;;
		"owed: "*) main_run "${l#owed: }" </dev/null ;;
		esac
	done 3< "$W/next"
}

close_session() {
	next_answer reopen
	SESSION_N=$((SESSION_N + 1)); SESSION="dry-$RUN-$SESSION_N"; CLAUDE_CODE_SESSION_ID=$SESSION
	: > "$W/pending"; : > "$W/hung"
	awk '{print $1, $2, "gone"}' "$W/agents" > "$W/agents.tmp"; mv "$W/agents.tmp" "$W/agents"
	log "session closed; reopened as $SESSION"
}

main_stop() { # 0 when main had something to do
	out=$(hook "$LAB/main-stop.sh" "$(hook_in '{session_id: $s, hook_event_name: "Stop", stop_hook_active: false, last_assistant_message: ""}')")
	[ -n "$out" ] || return 1
	msg=$(printf '%s' "$out" | jq -r '.systemMessage // empty'); [ -z "$msg" ] || log "stop note: $msg"
	reason=$(printf '%s' "$out" | jq -r 'select(.decision == "block") | .reason')
	if [ -n "$reason" ]; then
		HOLDS=$((HOLDS + 1))
		if [ -n "$CLOSE_AT" ] && printf '%s' "$reason" | grep -q "/$CLOSE_AT\.sh"; then
			log "stop held: $reason"; CLOSE_AT=''; close_session; return 0
		fi
		printf '%s\n' "$reason" > "$W/held"
		while IFS= read -r l <&3; do
			case "$l" in "owed: "*) ;; *) continue ;; esac
			log "stop held: ${l#owed: sh "$LAB"/}"
			main_run "${l#owed: }" </dev/null
		done 3< "$W/held"
		return 0
	fi
	ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')
	[ -n "$ctx" ] || return 1
	printf '%s\n' "$ctx" > "$W/facts"
	while IFS= read -r l <&3; do
		case "$l" in "fact: "*) log "stop fact: ${l#fact: }" ;; "offer: "*) main_run "${l#offer: }" </dev/null ;; esac
	done 3< "$W/facts"
	return 0
}

settle() {
	i=0
	while [ "$i" -lt 400 ] && [ "$STUCK" -eq 0 ]; do
		i=$((i + 1))
		if [ -s "$W/pending" ]; then
			aid=$(head -1 "$W/pending"); sed -i '' 1d "$W/pending"
			run_agent "$aid"
			while main_stop; do :; done
		elif main_stop; then :
		else return 0; fi
	done
	[ "$STUCK" -eq 1 ] || fail "settle did not end"
}

# --- the run -----------------------------------------------------------------

repo() {
	mkdir -p "$W/$1"
	git -C "$W/$1" init -q
	printf 'echo a\n' > "$W/$1/a.sh"; printf 'echo b\n' > "$W/$1/b.sh"
	git -C "$W/$1" add -A; git -C "$W/$1" -c user.name=lab -c user.email=lab@lab commit -qm first
}
commit() {
	printf 'echo %s\n' "$2" >> "$W/$1/$2"
	git -C "$W/$1" add -A; git -C "$W/$1" -c user.name=author -c user.email=a@a commit -qm "$2"
}
latest_build() {
	sh "$LAB/view.sh" --effort "$EFFORT" | jq -r --arg t "$W/$1" '[.[] | select(.type == "build.submitted")] as $b
		| [.[] | select(.type == "job.dispatched" and .body.tree == $t) | .seq] as $j
		| [$b[] | select(.job | IN($j[]))] | last | .seq'
}

directive() {
	set -- $1
	case "$1" in
	kinds) LAB_KINDS=$2; export LAB_KINDS ;;
	repo) repo "$2" ;;
	commit) commit "$2" "$3" ;;
	build) next_answer; main_run "$(sh "$LAB/gate.sh" --effort "$EFFORT" --step build --tree "$W/$2" --task "$words")" ;;
	test) next_answer; main_run "$(sh "$LAB/gate.sh" --effort "$EFFORT" --step test --tree "$W/$2")" ;;
	plan) next_answer; main_run "$(sh "$LAB/gate.sh" --effort "$EFFORT" --step test-plan --about "$(latest_build "$2")")" ;;
	pr-open) shift; id=$1 name=$2; shift 2
		sh "$LAB/remote.sh" --effort "$EFFORT" --open --pr "$id" --tree "$W/$name" \
			--base "$(git -C "$W/$name" rev-list --max-parents=0 HEAD)" --head "$(git -C "$W/$name" rev-parse HEAD)" \
			${1:+--threads "$(jq -c . "$RUNDIR/$1")"} >/dev/null ;;
	fetch) next_answer; main_run "sh $LAB/remote.sh --effort $EFFORT --fetch --pr $2" ;;
	request) next_answer; main_run "sh $LAB/remote.sh --effort $EFFORT --request --pr $2" ;;
	push) log "remote @$(at_events): the author pushes to $2"; commit "$3" "$4"
		CLAUDE_CODE_SESSION_ID=$SESSION sh "$LAB/remote.sh" --effort "$EFFORT" --push --pr "$2" --head "$(git -C "$W/$3" rev-parse HEAD)" --replies "$(jq -c . "$RUNDIR/$5")" >/dev/null
		: ;;
	close-session) close_session ;;
	close-at-owed) CLOSE_AT=$2 ;;
	settle) settle ;;
	expect | expect-log) ;;
	'') ;;
	*) fail "unknown directive $1" ;;
	esac
}

# the event sequence per root, without seqs or ids
expected() {
	sh "$LAB/view.sh" --effort "$EFFORT" | jq -L "$LAB/c" --arg run "$RUN" 'include "sequence"; sequence($run)' > "$OUT/expected.json"
}

checks() {
	view=$(sh "$LAB/view.sh" --effort "$EFFORT")
	left=$(sh "$LAB/owes.sh" --effort "$EFFORT" | jq -sc '[.[] | select(.owed != null or .waiting != [])]')
	{
		printf '%s' "$view" | jq -c '{check: "every job ended once", ok: ([.[] | select(.type == "job.dispatched") | .seq] as $j
			| [.[] | select((.type | endswith(".submitted")) or .type == "job.ended") | .job] as $x
			| all($j[]; . as $s | ($x | map(select(. == $s)) | length) == 1))}'
		jq -nc --argjson l "$left" '{check: "nothing owed or waiting at the end", ok: ($l == [])}'
		printf '%s' "$view" | jq -c '. as $e | {check: "a job'"'"'s events keep its root", ok: all(.[] | select(.job != null and .type != "job.assigned");
			. as $x | ($e[] | select(.seq == $x.job) | .root) as $r | $r == null or $r == $x.root)}'
		printf '%s' "$view" | jq -c '{check: "every job had its act", ok: all(.[] | select(.type == "job.dispatched"); .body.act != {})}'
		jq -nc --argjson f "$FAILED" '{check: "the driver met no failure", ok: ($f == 0)}'
		grep '^expect-log ' "$RUNDIR/plan" | sed 's/^expect-log //' | while IFS= read -r x; do
			if grep -Eq -- "$x" "$OUT/driver.log"; then ok=true; else ok=false; fi
			jq -nc --arg x "log: $x" --argjson ok "$ok" '{check: $x, ok: $ok}'
		done
		grep '^expect ' "$RUNDIR/plan" | sed 's/^expect //' | while IFS= read -r x; do
			printf '%s' "$view" | jq -c --arg x "$x" "{check: \$x, ok: ($x)}" 2>/dev/null || jq -nc --arg x "$x" '{check: $x, ok: false}'
		done
	} | jq -s '{passed: all(.[]; .ok), holds: '"$HOLDS"', checks: .}' > "$OUT/checks.json"
}

dry_run() {
	RUN=$1; RUNDIR=$LAB/c/runs/$RUN; OUT=$SPIKE/evidence/dry/$RUN
	[ -f "$RUNDIR/plan" ] || { echo "driver: no run $RUN" >&2; return 1; }
	W=$(mktemp -d "${TMPDIR:-/tmp}/dry.XXXXXX")
	EFFORT=$W/effort; mkdir -p "$EFFORT/acts" "$EFFORT/events" "$OUT"; : > "$OUT/driver.log"
	cp "$RUNDIR"/acts/*.json "$EFFORT/acts/" 2>/dev/null || true
	: > "$W/agents"; : > "$W/pending"; : > "$W/hung"
	CLAUDE_CONFIG_DIR=$W/config SCOPE_GRANT=1 WAIT_ASSIGN=1 LAB_KINDS=shell
	export EFFORT CLAUDE_CONFIG_DIR SCOPE_GRANT WAIT_ASSIGN LAB_KINDS
	SESSION_N=1 SESSION="dry-$RUN-1"; CLAUDE_CODE_SESSION_ID=$SESSION; export CLAUDE_CODE_SESSION_ID
	ANSWER_N=0 AGENT_N=0 TOOL_N=0 HOLDS=0 FAILED=0 STUCK=0 CLOSE_AT=''
	while IFS= read -r d <&3; do directive "$d" </dev/null; done 3< "$RUNDIR/plan"
	[ "$ANSWER_N" -eq "$(wc -l < "$RUNDIR/answers.txt" | tr -d ' ')" ] || fail "used $ANSWER_N of the answers"
	expected; checks
	rm -rf "$OUT/events" "$OUT/hook-log"
	cp -R "$EFFORT/events" "$OUT/events"; cp -R "$EFFORT/hook-log" "$OUT/hook-log" 2>/dev/null || true
	printf '%s: %s events, sanity %s\n' "$RUN" "$(ls "$EFFORT/events" | grep -c json)" \
		"$(jq -r 'if .passed then "pass" else "FAIL: " + ([.checks[] | select(.ok | not) | .check] | join("; ")) end' "$OUT/checks.json")"
}

[ $# -gt 0 ] || { echo "usage: driver.sh RUN... | all" >&2; exit 1; }
[ "$1" != all ] || set -- $(ls "$LAB/c/runs")
for r in "$@"; do dry_run "$r"; done
