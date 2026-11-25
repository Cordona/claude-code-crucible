#!/bin/sh
# Stop-hook probe kit: records how Claude Code behaves around SubagentStop.
#   run.sh <probe>   run one probe (the list is in the usage line at the end;
#                    results.md says what each one asks)
#   run.sh all       run every headless probe, one after the other
#   run.sh P2c [NAME], P2c-key KEYS, P2c-end   interactive (tmux) probes:
#                    P2c human interrupt, P2x human exits main while busy;
#                    P16b and P17b, run.sh P16b|P17b then PN=<name> -key/-end
# Each probe gets a fresh sandbox project under $SB/<probe> (outside the
# owner's home, so no owner CLAUDE.md loads), stand-in agents on haiku, the
# hook hooks/hook.sh on every event logged, and a headless main in bypass
# mode. Raw evidence is copied to logs/<probe>/.
set -eu
K=$(cd "$(dirname "$0")" && pwd)
SB=/Users/Shared/crucible-sandbox/stop-hook-probe
export CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg

# fgit: git for the fixtures only, with no global or system config (so the
# owner's signing setup is never used) and an unsigned fixture identity.
fgit() {
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=Fixture -c user.email=fixture@example.test \
		-c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

# mkagent NAME [MAXTURNS] [EXTRA_STEPS] [MODEL] [TOOLS]: a stand-in agent.
# STEP1 replaces its first command.
mkagent() {
	name=$1 mt=${2-} extra=${3-} model=${4:-haiku} atools=${5:-Bash}
	W="$S/work"
	{
		printf -- '---\nname: %s\ndescription: Probe stand-in %s. Runs a fixed recipe in a test sandbox.\ntools: %s\nmodel: %s\n' "$name" "$name" "$atools" "$model"
		[ -z "$mt" ] || printf 'maxTurns: %s\n' "$mt"
		printf -- '---\n\n'
		cat <<EOF
You are a stand-in agent in a test sandbox, named $name. Follow this recipe exactly and do nothing else. Use only the Bash tool unless a step names another tool, one tool call per step. Your work file is $W/$name.txt.

1. Run: ${STEP1:-printf 'start $name\n' >> $W/$name.txt}
$extra
Last: give a one-line final answer: "$name done."

If you receive a message saying a stop hook held or blocked your stop, it contains a line starting with "TOKEN:". Append that line, exactly as given from "TOKEN:" to its end, to $W/$name.txt with one Bash printf command, then give the one-line final answer again. Do this every time it happens.

If a tool call is denied by a hook, the denial holds a line starting with "TOKEN:". Append that line, exactly as given, to $W/$name.txt with one Bash printf command, then go on with the next step.

If you later receive a new message with "TASK: <word>", run: printf 'task <word>\n' >> $W/$name.txt (with the word in place of <word>), then give the one-line final answer again.
EOF
	} >"$S/.claude/agents/$name.md"
}

# policy TYPE ASSIGNMENTS: the hook's SubagentStop policy for that type.
policy() { printf '%s\n' "$2" >"$S/policy/$1"; }

# setup PROBE [STOP_TIMEOUT]: a fresh sandbox project. SETTINGS_ENV (JSON)
# becomes the settings "env" block; TOOLS is the Pre/PostToolUse matcher.
setup() {
	P=$1 S="$SB/$1"
	rm -rf -- "${S:?}"
	mkdir -p "$S/.claude/agents" "$S/hooks" "$S/policy" "$S/work" "$S/logs/hooks" "$S/state"
	cp "$K/hooks/hook.sh" "$S/hooks/hook.sh"
	h() { jq -nc --arg c "sh $S/hooks/hook.sh $1" --arg m "${2-}" --arg to "${3-}" \
		'{hooks: [{type: "command", command: $c} + (if $to == "" then {} else {timeout: ($to|tonumber)} end)]} + (if $m == "" then {} else {matcher: $m} end)'; }
	senv=${SETTINGS_ENV:-'{}'}
	tools=${TOOLS:-'Agent|Task|SendMessage|TaskStop|TaskOutput'}
	jq -n --argjson pre "$(h PreToolUse "$tools")" --argjson post "$(h PostToolUse "$tools")" \
		--argjson ss "$(h SubagentStop '' "${2-}")" --argjson sst "$(h SubagentStart)" --argjson st "$(h Stop)" \
		--argjson se "$(h SessionEnd)" --argjson sb "$(h SessionStart)" --argjson pr "$(h PermissionRequest)" '
		{hooks: {PreToolUse: [$pre], PostToolUse: [$post], SubagentStop: [$ss], SubagentStart: [$sst],
			Stop: [$st], SessionEnd: [$se], SessionStart: [$sb], PermissionRequest: [$pr]}}
		+ (if $env == {} then {} else {env: $env} end)' --argjson env "$senv" >"$S/.claude/settings.json"
}

# main PROMPT [LIMIT_S] [POST_WAIT_S] [KILL_AFTER_S]: headless main, killed by
# PID past LIMIT. PROC_ENV (VAR=value words) goes into main's process env.
# PERM is the permission mode (default bypassPermissions); FLAG_SETTINGS, a
# --settings file. MAIN_DIR is main's working folder (default the
# sandbox project), EXTRA_ARGS more claude flags.
main() {
	printf '%s\n' "$1" >"$S/logs/main-prompt.txt"
	printf 'mode=%s settings=%s extra=%s dir=%s\n' "${PERM:-bypassPermissions}" "${FLAG_SETTINGS-}" "${EXTRA_ARGS-}" "${MAIN_DIR:-$S}" >"$S/logs/main-args.txt"
	(
		cd "${MAIN_DIR:-$S}"
		exec env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT -u SETTINGS_ENV -u TOOLS -u PROC_ENV ${PROC_ENV-} \
			claude -p "$1" --permission-mode "${PERM:-bypassPermissions}" --output-format stream-json --verbose \
			--debug-file "$S/logs/debug.txt" ${FLAG_SETTINGS:+--settings "$FLAG_SETTINGS"} ${EXTRA_ARGS-} <"/dev/null" >"$S/logs/main.jsonl" 2>"$S/logs/main.err"
	) &
	pid=$!
	echo "$pid" >"$S/logs/main.pid"
	t=0 lim=${2:-600}
	while kill -0 "$pid" 2>/dev/null && [ $t -lt "$lim" ]; do
		sleep 2; t=$((t + 2))
		# KILL_AFTER: SIGTERM main this many seconds after the first SubagentStart.
		if [ -n "${4-}" ] && [ ! -f "$S/logs/main-killed.txt" ] && ls "$S/logs/hooks" | grep -q '^SubagentStart'; then
			ks=${ks:-$t}
			if [ $((t - ks)) -ge "$4" ]; then kill -TERM "$pid"; date +%s >"$S/logs/main-killed.txt"; fi
		fi
	done
	if kill -0 "$pid" 2>/dev/null; then echo "main killed by kit after ${lim}s" >>"$S/logs/main.err"; kill "$pid"; fi
	rc=0; wait "$pid" || rc=$?
	printf 'main exit %s after %ss at %s\n' "$rc" "$t" "$(date +%s)" >>"$S/logs/main.err"
	[ "${3:-0}" -eq 0 ] || sleep "$3"
	collect
}

# tools_tsv: every sub-agent tool call of this run, from the sub-agent
# transcripts (only the facts: tool, command or path, is_error, result text).
tools_tsv() {
	# Main's project folder, and the worktree's if main entered one (P19).
	pd="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "${MAIN_DIR:-$S}" | tr '/.' '--')"
	pw="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$S/space/efforts/e1/worktrees/t1" | tr '/.' '--')"
	for d in "$pd" "$pw"; do [ ! -d "$d" ] || printf '%s\n' "$d"; done | xargs -I{} find {} -path '*/subagents/agent-*.jsonl' -newer "$S/logs/main-prompt.txt" | while read -r tf; do
		id=$(basename "$tf" .jsonl); id=${id#agent-}
		typ=$(ls "$S/logs/hooks"/SubagentStart-* 2>/dev/null | grep -v '\.trace$' | xargs cat | jq -r --arg i "$id" 'select(.input.agent_id == $i) | .input.agent_type' | head -n 1)
		jq -rs --arg a "${typ:-?} $id" '
			[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | {id, name, input}] as $u
			| [.[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result")
				| {id: .tool_use_id, e: (.is_error // false), c: (.content | if type == "array" then map(.text // "") | join(" ") else tostring end)}] as $r
			| $u[] | . as $x | ($r | map(select(.id == $x.id)) | first) as $y
			| [$a, $x.name, (($x.input.command // $x.input.file_path // "") | gsub("\n"; "\\n")), ($y.e // "none"), (($y.c // "") | gsub("\n"; " ") | .[0:400])] | @tsv' "$tf"
	done
}

collect() {
	O="$K/logs/$P"
	rm -rf -- "${O:?}"; mkdir -p "$O"
	cp -R "$S/logs/." "$O/"
	cl=${CLDIR:-$S/.claude}
	cp -R "$S/work" "$S/policy" "$cl/agents" "$O/"
	cp "$cl/settings.json" "$O/settings.json"
	tools_tsv >"$O/tools.tsv"
	[ ! -f "$S/state/commits" ] || cp "$S/state/commits" "$O/commits.txt"
	claude --version >"$O/claude-version.txt"
	echo "collected $P into $O"
}

# p16fixture PROBE: the P16 layout. Main runs in a repo ($S/repo), the
# agent's tree is a worktree outside it ($S/trees/t1), the report space is
# outside both ($S/space).
p16fixture() {
	TOOLS=${TOOLS:-'Agent|Bash|Write'} setup "$1"
	R="$S/repo" T="$S/trees/t1" SP="$S/space"
	fgit init -q -b main "$R"; mkdir -p "$R/tests" "$S/trees" "$SP"
	printf '#!/bin/sh\necho tests ok\n' >"$R/tests/run.sh"; printf '#!/bin/sh\necho hi\n' >"$R/x.sh"
	fgit -C "$R" add -A; fgit -C "$R" commit -q -m fixture
	fgit -C "$R" worktree add -q "$T" -b t1; printf 'echo changed\n' >>"$T/x.sh"
}

BG='with the Agent tool, in the background (run_in_background: true)'
WAIT='Then wait until every agent you started has finished; you will be notified. Do not read, write or run anything yourself except as told. When all have finished, reply with one line: DONE.'

case ${1-} in
P1)
	setup P1
	mkagent p1-twice; policy p1-twice BLOCK_N=2
	mkagent p1-cap; policy p1-cap BLOCK_N=8
	main "In one message, start two agents $BG: subagent_type \"p1-twice\" with prompt \"go\", and subagent_type \"p1-cap\" with prompt \"go\". $WAIT" ;;
P2a)
	setup P2a
	mkagent p2-turns 2 "2. Run: printf 'step 2\n' >> $SB/P2a/work/p2-turns.txt
3. Run: printf 'step 3\n' >> $SB/P2a/work/p2-turns.txt
4. Run: printf 'step 4\n' >> $SB/P2a/work/p2-turns.txt
5. Run: printf 'step 5\n' >> $SB/P2a/work/p2-turns.txt"
	main "Start one agent $BG, subagent_type \"p2-turns\", prompt \"go\". $WAIT" ;;
P2b)
	setup P2b
	mkagent p2-kill '' "2. Run, in the foreground (never run_in_background): perl -e 'sleep 100'
3. Run: printf 'after sleep\n' >> $SB/P2b/work/p2-kill.txt"
	main "Start one agent $BG, subagent_type \"p2-kill\", prompt \"go\". Note its agent id. Then run the Bash command: sleep 20. Then stop that agent with the TaskStop tool (load it with ToolSearch first if needed), giving its id. Then wait 10 seconds (Bash: sleep 10) and reply with one line: DONE, plus what TaskStop returned." 300 ;;
P2d)
	setup P2d
	mkagent p2-orphan '' "2. Run, in the foreground (never run_in_background): perl -e 'sleep 45'
3. Run: printf 'after sleep\n' >> $SB/P2d/work/p2-orphan.txt"
	main "Start one agent $BG, subagent_type \"p2-orphan\", prompt \"go\". Do NOT wait for it. Immediately reply with one line: DONE." 300 90 ;;
P2k)
	# Main's process gets SIGTERM (by PID) 15 s after the agent starts, while
	# the agent is in a 60 s sleep; then the kit waits 75 s for any late trace.
	setup P2k
	mkagent p2-term '' "2. Run, in the foreground (never run_in_background): perl -e 'sleep 60'
3. Run: printf 'after sleep\n' >> $SB/P2k/work/p2-term.txt"
	main "Start one agent $BG, subagent_type \"p2-term\", prompt \"go\". $WAIT" 300 75 15 ;;
P1c)
	setup P1c
	mkagent p1-cap25; policy p1-cap25 BLOCK_N=25
	main "Start one agent $BG, subagent_type \"p1-cap25\", prompt \"go\". $WAIT" 600 ;;
P9)
	# PreToolUse/PostToolUse also on Bash and Write; background Bash denied.
	TOOLS='Agent|Task|SendMessage|TaskStop|TaskOutput|Bash|Write' setup P9
	: >"$S/policy/pretool-deny-bg"
	W="$S/work"
	mkagent p9-tools '' "2. With the Write tool (not Bash), write the text written to the file $W/p9-tools-write.txt.
3. With the Bash tool, with the parameter run_in_background set to true, run: printf 'bg ran\n' >> $W/p9-tools.txt
4. Run, in the foreground: printf 'after denial\n' >> $W/p9-tools.txt" haiku 'Bash, Write'
	mkagent p9-long1 '' "2. Run this one command in the foreground; do not set the timeout or run_in_background parameters: perl -e 'sleep 150'; printf 'long1 finished\n' >> $W/p9-long1.txt
3. Run: printf 'after long1\n' >> $W/p9-long1.txt"
	mkagent p9-long2 '' "2. Run this one command in the foreground with the timeout parameter set to 600000 and run_in_background not set: perl -e 'sleep 150'; printf 'long2 finished\n' >> $W/p9-long2.txt
3. Run: printf 'after long2\n' >> $W/p9-long2.txt"
	mkagent p9-sleep '' "2. Run this one command in the foreground; do not set run_in_background: sleep 30; printf 'sleep finished\n' >> $W/p9-sleep.txt
3. Run: printf 'after sleep\n' >> $W/p9-sleep.txt"
	main "In one message, start four agents $BG, each with prompt \"go\": subagent_type \"p9-tools\", \"p9-long1\", \"p9-long2\" and \"p9-sleep\". $WAIT" 600 ;;
P10a)
	# p10-slow's SubagentStop hook sleeps 25 s; p10-fast ends during it, so
	# main gets a turn (and a Stop) while that hook still runs.
	setup P10a
	mkagent p10-slow; policy p10-slow SLEEP=25
	mkagent p10-fast '' "2. Run, in the foreground (never run_in_background): perl -e 'sleep 8'"
	main "In one message, start two agents $BG, each with prompt \"go\": subagent_type \"p10-slow\" and \"p10-fast\". Each time you are notified that one has finished, reply with one line naming it. When both have finished, reply with one line: DONE." 300 ;;
P10b-turns)
	setup P10b-turns
	mkagent p10-turns 2 "2. Run: printf 'step 2\n' >> $SB/P10b-turns/work/p10-turns.txt
3. Run: printf 'step 3\n' >> $SB/P10b-turns/work/p10-turns.txt
4. Run: printf 'step 4\n' >> $SB/P10b-turns/work/p10-turns.txt"
	main "Start one agent $BG, subagent_type \"p10-turns\", prompt \"go\". Reply with one line, then wait until it has finished; you will be notified. Then reply with one line: DONE, plus what you were told." 300 ;;
P10b-err)
	setup P10b-err
	mkagent p10-apierr '' '' claude-nonexistent-model-0
	main "Start one agent $BG, subagent_type \"p10-apierr\", prompt \"go\". Reply with one line, then wait until it has finished; you will be notified. Then reply with one line: DONE, plus what you were told." 300 ;;
P12 | P12s)
	# P12s: the PostToolUse hook on SendMessage sleeps 8 s.
	setup "$1"
	mkagent p12-hot
	[ "$1" = P12 ] || printf 'POST_SLEEP=8\n' >"$S/policy/post-SendMessage"
	main "Start one agent $BG, subagent_type \"p12-hot\", prompt \"go\". Wait until it has finished; you will be notified. Then, three times in turn, send it a new message with the SendMessage tool (load it with ToolSearch if needed), to its agent id: first \"TASK: two\", then \"TASK: three\", then \"TASK: four\", each only after it has finished the one before. Then reply with one line: DONE." 400 ;;
P13a | P13a-proc | P13a-ctl | P13a-ctl700)
	# Bash limits from env: P13a in the settings "env" block, P13a-proc in
	# main's process env, P13a-ctl with neither (the control). p13-def: 150 s, no timeout. p13-max: timeout
	# 900000 on a 5 s command (is it accepted?). p13-700 (P13a, and P13a-ctl700, the 700 s control with no env): timeout
	# 900000 on a 700 s command.
	if [ "$1" = P13a-ctl ] || [ "$1" = P13a-ctl700 ]; then
		TOOLS='Bash' setup "$1"
	elif [ "$1" = P13a ]; then
		SETTINGS_ENV='{"BASH_DEFAULT_TIMEOUT_MS": "600000", "BASH_MAX_TIMEOUT_MS": "1800000"}' TOOLS='Bash' setup P13a
	else
		TOOLS='Bash' setup P13a-proc
		PROC_ENV='BASH_DEFAULT_TIMEOUT_MS=600000 BASH_MAX_TIMEOUT_MS=1800000'
	fi
	W="$S/work"
	mkagent p13-def '' "2. Run this one command in the foreground; do not set the timeout or run_in_background parameters: perl -e 'sleep 150'; printf 'def finished\n' >> $W/p13-def.txt
3. Run: printf 'after def\n' >> $W/p13-def.txt"
	mkagent p13-max '' "2. Run this one command in the foreground with the timeout parameter set to 900000 and run_in_background not set: perl -e 'sleep 5'; printf 'max finished\n' >> $W/p13-max.txt. If the call is refused, append the refusal message's first line to $W/p13-max.txt with printf and go on.
3. Run: printf 'after max\n' >> $W/p13-max.txt"
	list="\"p13-def\" and \"p13-max\""
	if [ "$1" = P13a ] || [ "$1" = P13a-ctl700 ]; then
		mkagent p13-700 '' "2. Run this one command in the foreground with the timeout parameter set to 900000 and run_in_background not set: perl -e 'sleep 700'; printf '700 finished\n' >> $W/p13-700.txt. If the call is refused, append the refusal message's first line to $W/p13-700.txt with printf and go on.
3. Run: printf 'after 700\n' >> $W/p13-700.txt"
		list="\"p13-def\", \"p13-max\" and \"p13-700\""
	fi
	main "In one message, start agents $BG, each with prompt \"go\": subagent_type $list. $WAIT" 1000 ;;
P13b)
	# The PreToolUse hook adds timeout 600000 to a sub-agent's Bash call.
	TOOLS='Bash' setup P13b
	: >"$S/policy/pretool-add-timeout"
	mkagent p13-rw '' "2. Run this one command in the foreground; do not set the timeout or run_in_background parameters: perl -e 'sleep 150'; printf 'rw finished\n' >> $S/work/p13-rw.txt
3. Run: printf 'after rw\n' >> $S/work/p13-rw.txt
Before your final answer, append one line to $S/work/p13-rw.txt saying whether anything about step 2 surprised you (printf 'note: ...\n')."
	main "Start one agent $BG, subagent_type \"p13-rw\", prompt \"go\". $WAIT" 400 ;;
P13c)
	# A command that runs past its explicit timeout.
	TOOLS='Bash' setup P13c
	mkagent p13-over '' "2. Run this one command in the foreground with the timeout parameter set to 20000 and run_in_background not set: perl -e 'sleep 40'; printf 'over finished\n' >> $S/work/p13-over.txt
3. Run: printf 'after over\n' >> $S/work/p13-over.txt"
	main "Start one agent $BG, subagent_type \"p13-over\", prompt \"go\". $WAIT" 300 ;;
P14 | P14d)
	# BASH_MAX_TIMEOUT_MS (P14) or BASH_DEFAULT_TIMEOUT_MS (P14d) only in the
	# settings env block; every hook writes its own BASH_ env vars to <call>.env.
	if [ "$1" = P14 ]; then senv='{"BASH_MAX_TIMEOUT_MS": "1800000"}'; else senv='{"BASH_DEFAULT_TIMEOUT_MS": "600000"}'; fi
	SETTINGS_ENV=$senv TOOLS='Bash' setup "$1"
	: >"$S/policy/dump-env"
	mkagent p14-env
	main "Start one agent $BG, subagent_type \"p14-env\", prompt \"go\". $WAIT" 200 ;;
P15n | P15a | P15c)
	# Permission mode default, not bypass. A --settings file's
	# permissions.allow grants only `sh <S>/w.sh` (append a line to a file)
	# and `perl`; project-scoped allow rules are dropped in an untrusted
	# workspace (debug: "workspace not yet trusted"), and a printf with a
	# >> redirect is not covered by Bash(printf:*). The PreToolUse hook adds
	# timeout 600000 to the sub-agent's Bash calls: P15n with updatedInput
	# only (no permissionDecision), P15a with permissionDecision allow, P15c
	# no hook rewrite (the control). Step 4 runs touch, which nothing grants.
	TOOLS='Agent|Bash' setup "$1"
	printf '#!/bin/sh\nprintf "%%s\\n" "$2" >> "$1"\n' >"$S/w.sh"
	jq -n --arg w "Bash(sh $S/w.sh:*)" '{permissions: {allow: [$w, "Bash(perl:*)"]}}' >"$S/logs/flag-settings.json"
	FLAG_SETTINGS="$S/logs/flag-settings.json"
	case $1 in P15n) echo nodecision >"$S/policy/pretool-add-timeout" ;; P15a) echo allow >"$S/policy/pretool-add-timeout" ;; esac
	W="$S/work" WS="sh $S/w.sh $S/work/p15-perm.txt"
	STEP1="$WS 'start p15-perm'" mkagent p15-perm '' "2. Run this one command in the foreground; do not set the timeout or run_in_background parameters: perl -e 'sleep 150'
3. Run: $WS 'perm finished'
4. Run: touch $W/p15-touched.txt
   If that call is refused or not allowed, run: $WS 'touch refused', then go on.
5. Run: $WS 'after touch'
Use exactly these commands; never write the work file any other way."
	PERM=default main "Start one agent $BG, subagent_type \"p15-perm\", prompt \"go\". $WAIT" 400 ;;
P16a | P16a-dirs | P16a-bypass | P16c | P16c-in | P16d-set-default | P16d-set-acceptEdits | P16d-add-default | P16d-add-acceptEdits)
	# Real-use layout: main runs in a repo ($S/repo), the agent's tree is a
	# worktree outside it ($S/trees/t1), the report goes to a space outside
	# both ($S/space). No allow-list. Main headless in default mode unless
	# the case says acceptEdits. The tool calls and their results land in
	# tools.tsv.
	p16fixture "$1"
	ON_REFUSAL="If a step is refused or not allowed, do not try another way and do not write anywhere else; go on with the next step. In your final answer, list each step with done or refused."
	case $1 in
	P16a | P16a-dirs | P16a-bypass)
		# P16a-dirs: tree and space added as working dirs (--add-dir); P16a-bypass:
		# main in bypassPermissions. P16a: neither.
		[ "$1" != P16a-dirs ] || EXTRA_ARGS="--add-dir $T --add-dir $SP"
		for m in none default acceptEdits plan bypassPermissions dontAsk; do
			STEP1=pwd mkagent "p16-$m" '' "2. With the Write tool, write the text in tree to the file $T/p16-$m-in.txt
3. With the Write tool, write the text report to the file $SP/p16-$m-report.txt
4. Run: touch $T/p16-$m-touch.txt
5. Run: ls $T
$ON_REFUSAL" haiku 'Bash, Write'
			[ "$m" = none ] || M=$m perl -pi -e 's/^model: haiku$/model: haiku\npermissionMode: $ENV{M}/' "$S/.claude/agents/p16-$m.md"
		done
		prompt="In one message, start six agents $BG, each with prompt \"go\": subagent_type \"p16-none\", \"p16-default\", \"p16-acceptEdits\", \"p16-plan\", \"p16-bypassPermissions\" and \"p16-dontAsk\". $WAIT Include each agent's final answer." ;;
	P16c | P16c-in)
		# P16c-in: the tree is added as a working dir (--add-dir), to tell
		# "outside the working dirs" from Claude Code's own command guards.
		[ "$1" = P16c ] || EXTRA_ARGS="--add-dir $T"
		STEP1=pwd mkagent p16-forms '' "Run each of these as one Bash command, exactly as written, one call each:
2. git -C $T diff
3. git -C $T status
4. cd $T && git diff
5. cd $T && sh tests/run.sh
6. sh $T/tests/run.sh
7. shellcheck $T/x.sh
8. sh $T/tests/run.sh; echo rc=\$?
9. A heredoc, exactly these three lines as one command:
cat > $SP/f.json <<'EOF'
{\"a\":\"b\"}
EOF
10. The same heredoc into the tree:
cat > $T/f.json <<'EOF'
{\"a\":\"b\"}
EOF
Controls, in main's own working folder:
11. git status
12. git -C $R status
13. sh tests/run.sh
14. shellcheck x.sh
15. ls $T
$ON_REFUSAL"
		prompt="Start one agent $BG, subagent_type \"p16-forms\", prompt \"go\". $WAIT Include its final answer." ;;
	P16d-*)
		STEP1=pwd mkagent p16-rep '' "2. With the Write tool, write the text {\"report\": 1} to the file $SP/report.json
3. With the Write tool, write the text in tree to the file $T/p16-in.txt
$ON_REFUSAL" haiku 'Bash, Write'
		case $1 in
		P16d-set-*) jq -n --arg d "$SP" '{permissions: {additionalDirectories: [$d]}}' >"$S/logs/flag-settings.json"; FLAG_SETTINGS="$S/logs/flag-settings.json" ;;
		P16d-add-*) EXTRA_ARGS="--add-dir $SP" ;;
		esac
		prompt="Start one agent $BG, subagent_type \"p16-rep\", prompt \"go\". $WAIT Include its final answer." ;;
	esac
	case $1 in *acceptEdits) PERM=acceptEdits ;; P16a-bypass) PERM=bypassPermissions ;; *) PERM=default ;; esac
	mv "$S/.claude" "$R/.claude"; CLDIR="$R/.claude" MAIN_DIR="$R"
	main "$prompt" 300
	ls -la "$T" "$SP" >"$K/logs/$1/files-after.txt" 2>&1 ;;
P2e)
	setup P2e
	mkagent p2-apierr '' '' claude-nonexistent-model-0
	main "Start one agent $BG, subagent_type \"p2-apierr\", prompt \"go\". $WAIT Include in your line what the agent's result or error was." 300 ;;
P3)
	setup P3
	mkagent p3-hot
	main "Start one agent $BG, subagent_type \"p3-hot\", prompt \"go\". Wait until it has finished; you will be notified. Then send it a new message with the SendMessage tool (load it with ToolSearch if needed), to its agent id, with the message \"TASK: second\". Wait until it has finished again. Then reply with one line: DONE." ;;
P4)
	setup P4
	for x in a b c d e; do mkagent "p4-$x"; policy "p4-$x" 'BLOCK_N=1 BARRIER=5'; done
	main "In one single message, start five agents $BG, each with prompt \"go\": subagent_type \"p4-a\", \"p4-b\", \"p4-c\", \"p4-d\" and \"p4-e\". $WAIT" ;;
P5)
	setup P5
	mkagent p5-fg; mkagent p5-bg
	main "First start one agent with the Agent tool in the FOREGROUND (run_in_background: false), subagent_type \"p5-fg\", prompt \"go\", and wait for its result. Then start one agent $BG, subagent_type \"p5-bg\", prompt \"go\". $WAIT" ;;
P6)
	setup P6
	for s in 30 60 90 120; do mkagent "p6-s$s"; policy "p6-s$s" "BLOCK_N=1 SLEEP=$s"; done
	main "In one single message, start four agents $BG, each with prompt \"go\": subagent_type \"p6-s30\", \"p6-s60\", \"p6-s90\" and \"p6-s120\". $WAIT" 900 ;;
P6t)
	setup P6t 10
	mkagent p6-t10; policy p6-t10 'BLOCK_N=1 SLEEP=20'
	main "Start one agent $BG, subagent_type \"p6-t10\", prompt \"go\". $WAIT" 300 ;;
P6q)
	setup P6q
	mkagent p6-q; policy p6-q 'BLOCK_N=1 LOCK=5'
	main "In one single message, start twelve agents $BG, all with subagent_type \"p6-q\" and prompt \"go\" (descriptions q1 to q12). $WAIT" 900 ;;
P7)
	setup P7
	mkagent p7-m1 1; policy p7-m1 BLOCK_N=1
	mkagent p7-m2 2; policy p7-m2 BLOCK_N=1
	main "In one message, start two agents $BG, each with prompt \"go\": subagent_type \"p7-m1\" and \"p7-m2\". $WAIT Include each agent's final result in your line." 400 ;;
P8)
	setup P8
	mkagent p8-fg; policy p8-fg BLOCK_N=1
	main "Start one agent with the Agent tool in the FOREGROUND (run_in_background: false), subagent_type \"p8-fg\", prompt \"go\", and wait for its result. Then reply with one line: DONE, plus its result." 300 ;;
P2c)
	# Interactive main in tmux (tmux session stop-hook-probe-p2c), two
	# background agents busy in a 90 s sleep. run.sh P2c starts it and
	# accepts the folder-trust dialog; the "human" then acts with
	# `run.sh P2c-key <tmux keys...>` (each call logs the key and the pane
	# after it), and `run.sh P2c-end` exits main and collects. A second argument (and PN=<name> for -key and -end) runs it under another probe name, such as P2x for the exit-while-busy run.
	setup "${2:-P2c}"
	for a in p2-int1 p2-int2; do mkagent "$a" '' "2. Run, in the foreground (never run_in_background): perl -e 'sleep 90'
3. Run: printf 'after sleep\n' >> $S/work/$a.txt"; done
	prompt="In one message, start two agents $BG, each with prompt \"go\": subagent_type \"p2-int1\" and \"p2-int2\". $WAIT"
	printf '%s\n' "$prompt" >"$S/logs/main-prompt.txt"
	tmux new-session -d -s stop-hook-probe-p2c -x 200 -y 50 -c "$S" \
		"env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR claude --permission-mode bypassPermissions --debug-file $S/logs/debug.txt \"\$(cat $S/logs/main-prompt.txt)\"; sleep 5"
	sleep 6; tmux send-keys -t stop-hook-probe-p2c Down; tmux send-keys -t stop-hook-probe-p2c Enter
	echo started ;;
P16b)
	# Interactive main (tmux session stop-hook-probe-p2c) in the P16 layout,
	# permission mode default, no allow-list: one background agent hits asks.
	# The "human" acts with PN=P16b run.sh P2c-key ..., then PN=P16b run.sh P2c-end.
	p16fixture P16b
	STEP1=pwd mkagent p16-ask '' "2. With the Write tool, write the text report to the file $SP/p16b-report.txt
3. Run: touch $T/p16b-touch.txt
4. Run: git -C $T status
5. Run: ls $T
If a step is refused or not allowed, do not try another way; go on with the next step. In your final answer, list each step with done or refused." haiku 'Bash, Write'
	mv "$S/.claude" "$R/.claude"
	printf '%s\n' "Start one agent $BG, subagent_type \"p16-ask\", prompt \"go\". $WAIT Include its final answer." >"$S/logs/main-prompt.txt"
	printf 'mode=default interactive dir=%s\n' "$R" >"$S/logs/main-args.txt"
	tmux new-session -d -s stop-hook-probe-p2c -x 200 -y 50 -c "$R" \
		"env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR claude --permission-mode default --debug-file $S/logs/debug.txt \"\$(cat $S/logs/main-prompt.txt)\"; sleep 5"
	echo started ;;
P17a | P17b | P17c-default | P17c-acceptEdits | P17c-bypassPermissions | P17d-edit | P17d-both)
	# The P16 layout, no allow-list. A PreToolUse write gate
	# (policy/write-gate) allows a sub-agent's Write/Edit/Read in its tree and
	# to its report path, and denies Write/Edit in main's repo with a reason.
	# P17a headless, main default. P17b the same, interactive (run.sh P17b,
	# then PN=P17b run.sh P2c-key ..., P2c-end). P17c-<mode>: writes aimed at
	# the repo. P17d-*: no gate; a --settings deny rule on the space's
	# efforts/*/events/** (Edit only, or Edit and Write), main acceptEdits with
	# --add-dir of the space so writes there pass unless a rule stops them.
	TOOLS='Agent|Bash|Write|Edit|Read' p16fixture "$1"
	REP="$SP/report.json"
	case $1 in P17d-*) ;; *)
		printf 'WG_ALLOW="%s %s"\nWG_DENY="%s/"\nWG_REASON="Refused: write only in %s and %s. Write the file in your tree instead."\n' \
			"$T/" "$REP" "$R" "$T" "$REP" >"$S/policy/write-gate" ;;
	esac
	ON_REF="If a step is refused, read the refusal: if it tells you where to write instead, do the same step there; otherwise go on with the next step. In your final answer, list each step with done, redone elsewhere (say where) or refused."
	case $1 in
	P17a | P17b)
		STEP1=pwd mkagent p17-gate '' "2. With the Write tool, write the text new file to the file $T/p17-new.txt
3. With the Read tool, read $T/x.sh. Then with the Edit tool, in $T/x.sh replace the text echo hi with echo edited
4. With the Write tool, write the text {\"report\": 1} to the file $REP
$ON_REF" haiku 'Bash, Read, Write, Edit'
		prompt="Start one agent $BG, subagent_type \"p17-gate\", prompt \"go\". $WAIT Include its final answer." ;;
	P17c-*)
		STEP1=pwd mkagent p17-stray '' "2. With the Write tool, write the text stray to the file $R/p17-stray.txt
3. With the Read tool, read $R/x.sh. Then with the Edit tool, in $R/x.sh replace the text echo hi with echo stray
$ON_REF" haiku 'Bash, Read, Write, Edit'
		prompt="Start one agent $BG, subagent_type \"p17-stray\", prompt \"go\". $WAIT Include its final answer." ;;
	P17d-*)
		EV="$SP/efforts/e1/events"; mkdir -p "$EV"; printf '{"old": 1}\n' >"$EV/old.json"
		rules=$(jq -nc --arg e "Edit(/$SP/efforts/*/events/**)" --arg w "Write(/$SP/efforts/*/events/**)" --arg m "$1" \
			'if $m == "P17d-both" then [$e, $w] else [$e] end')
		jq -n --argjson d "$rules" '{permissions: {deny: $d}}' >"$S/logs/flag-settings.json"
		FLAG_SETTINGS="$S/logs/flag-settings.json" EXTRA_ARGS="--add-dir $SP"
		STEP1=pwd mkagent p17-ev '' "2. With the Write tool, write the text {\"new\": 1} to the file $EV/new.json
3. With the Read tool, read $EV/old.json. Then with the Edit tool, in $EV/old.json replace the text 1 with 2
4. With the Write tool, write the text {\"other\": 1} to the file $SP/efforts/e1/other.json
If a step is refused, do not try another way; go on with the next step. In your final answer, list each step with done or refused." haiku 'Bash, Read, Write, Edit'
		prompt="Start one agent $BG, subagent_type \"p17-ev\", prompt \"go\". $WAIT Include its final answer." ;;
	esac
	mv "$S/.claude" "$R/.claude"; CLDIR="$R/.claude" MAIN_DIR="$R"
	case $1 in
	P17b)
		printf '%s\n' "$prompt" >"$S/logs/main-prompt.txt"
		printf 'mode=default interactive dir=%s\n' "$R" >"$S/logs/main-args.txt"
		tmux new-session -d -s stop-hook-probe-p2c -x 200 -y 50 -c "$R" \
			"env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR claude --permission-mode default --debug-file $S/logs/debug.txt \"\$(cat $S/logs/main-prompt.txt)\"; sleep 5"
		echo started; exit 0 ;;
	P17c-*) PERM=${1#P17c-} ;;
	P17d-*) PERM=acceptEdits ;;
	*) PERM=default ;;
	esac
	main "$prompt" 300
	{ ls -laR "$T" "$SP"; git -C "$R" status --short; cat "$R/x.sh" "$T/x.sh"; } >"$K/logs/$1/files-after.txt" 2>&1 ;;
P18)
	# The layout as installed: main in a repo; the space holds
	# efforts/e1/worktrees/t1 (a worktree of the repo) and efforts/e1/reports/;
	# the space is in permissions.additionalDirectories (--settings). The
	# PreToolUse hooks match Agent|Write|Edit only, and the write gate allows
	# Write and Edit in the tree and to the report. No Read allow anywhere.
	# Main default, headless; the agent reads, greps, globs, then edits.
	TOOLS='Agent|Write|Edit' setup P18
	R="$S/repo" SP="$S/space"; T="$SP/efforts/e1/worktrees/t1" REP="$SP/efforts/e1/reports/1.json"
	fgit init -q -b main "$R"; mkdir -p "$R/tests" "$SP/efforts/e1/worktrees" "$SP/efforts/e1/reports"
	printf '#!/bin/sh\necho tests ok\n' >"$R/tests/run.sh"; printf '#!/bin/sh\necho hi\n' >"$R/x.sh"
	fgit -C "$R" add -A; fgit -C "$R" commit -q -m fixture
	fgit -C "$R" worktree add -q "$T" -b t1
	printf 'WG_TOOLS="Write|Edit"\nWG_ALLOW="%s/ %s"\n' "$T" "$REP" >"$S/policy/write-gate"
	jq -n --arg d "$SP" '{permissions: {additionalDirectories: [$d]}}' >"$S/logs/flag-settings.json"
	FLAG_SETTINGS="$S/logs/flag-settings.json"
	STEP1=pwd mkagent p18-read '' "2. With the Read tool, read $T/x.sh
3. With the Grep tool, search for echo in the folder $T
4. With the Glob tool, find files matching **/*.sh in the folder $T
Then, as the Bash stand-ins for those two (Grep and Glob may not exist in this build), run: grep -rn echo $T
and then run: find $T -name '*.sh'
5. With the Edit tool, in $T/x.sh replace the text echo hi with echo edited
6. With the Write tool, write the text {\"report\": 1} to the file $REP
If a step is refused, do not try another way; go on with the next step. In your final answer, list each step with done or refused." haiku 'Bash, Read, Grep, Glob, Write, Edit'
	mv "$S/.claude" "$R/.claude"; CLDIR="$R/.claude" MAIN_DIR="$R" PERM=default
	main "Start one agent $BG, subagent_type \"p18-read\", prompt \"go\". $WAIT Include its final answer." 300
	{ git -C "$T" diff; ls -la "$SP/efforts/e1/reports"; } >"$K/logs/P18/files-after.txt" 2>&1 ;;
P19-schema)
	# Main quotes the input schemas of its Agent and EnterWorktree tools.
	setup P19-schema
	PERM=default main "Do not call any tool except ToolSearch. Load EnterWorktree with ToolSearch if it is deferred. Then reply with the full input schema of your Agent tool and of your EnterWorktree tool: every parameter's name, type, whether it is required, and its description, verbatim, plus each tool's description verbatim." 200 ;;
P19a-front | P19a-param | P19a-hook | P19a-enter | P19a-main | P19a-enter-allow | P19a-main-allow | P19a-enter-bypass | P19a-main-bypass | P19a-iso-bypass | P19bc)
	# The P18 layout (space in additionalDirectories via --settings), main
	# default headless, plus a Makefile (test: sh tests/run.sh).
	# P19a-*: can a background agent's working directory be the tree?
	#   front: frontmatter cwd; param: a PreToolUse hook adds cwd to the Agent
	#   input; hook: SubagentStart prints {cwd, workingDirectory}; enter: the
	#   agent calls EnterWorktree path <tree>; main: main calls EnterWorktree
	#   path <tree> before starting it. The -allow variants add an allow rule
#   for EnterWorktree. The -bypass variants run main in bypassPermissions. iso: main
#   starts the agent with isolation: "worktree" (so it is pinned in
#   .claude/worktrees), and the agent tries EnterWorktree path <tree>. The write gate allows Write in the
	#   tree and in main's repo, so a relative Write shows where it lands.
	# P19bc: allow rules Bash(sh tests/run.sh), Bash(make test) and
	#   Bash(git -C * status*); the agent tries cd <tree> && <each>.
	TOOLS='Agent|Write|Edit|EnterWorktree' setup "$1"
	R="$S/repo" SP="$S/space"; T="$SP/efforts/e1/worktrees/t1"
	fgit init -q -b main "$R"; mkdir -p "$R/tests" "$SP/efforts/e1/worktrees" "$SP/efforts/e1/reports"
	printf '#!/bin/sh\necho tests ok\n' >"$R/tests/run.sh"; printf '#!/bin/sh\necho hi\n' >"$R/x.sh"
	printf 'test:\n\tsh tests/run.sh\n' >"$R/Makefile"
	fgit -C "$R" add -A; fgit -C "$R" commit -q -m fixture
	fgit -C "$R" worktree add -q "$T" -b t1
	printf 'WG_TOOLS="Write|Edit"\nWG_ALLOW="%s/ %s/"\n' "$T" "$R" >"$S/policy/write-gate"
	allow='[]'
	[ "$1" != P19bc ] || allow='["Bash(sh tests/run.sh)", "Bash(make test)", "Bash(git -C * status*)"]'
	case $1 in *-allow) allow='["EnterWorktree"]' ;; esac
	jq -n --arg d "$SP" --argjson a "$allow" '{permissions: {additionalDirectories: [$d], allow: $a}, worktree: {baseRef: "head"}}' >"$S/logs/flag-settings.json"
	FLAG_SETTINGS="$S/logs/flag-settings.json"
	ON="If a step is refused or fails, do not try another way; go on with the next step. In your final answer, list each step with its output or its exact refusal."
	BGP="with the Agent tool, in the background (run_in_background: true)"
	case $1 in
	P19a-*)
		c=${1#P19a-}; c=${c%-allow}; c=${c%-bypass}
		pre=''
		[ "$c" != iso ] || pre="2. With the EnterWorktree tool (load it with ToolSearch if needed), pass path $T (and no name).
"
		[ "$c" != enter ] || pre="2. With the EnterWorktree tool (load it with ToolSearch if needed), pass path $T (and no name).
"
		STEP1=pwd mkagent "p19-$c" '' "${pre}3. Run: pwd
4. With the Write tool, write the text relative to the file path p19-rel-$c.txt (exactly this relative path, no folder)
5. Run: ls
$ON" haiku 'Bash, Write, EnterWorktree, ToolSearch'
		case $c in
		front) M="$T" perl -pi -e 's/^model: haiku$/model: haiku\ncwd: $ENV{M}/' "$S/.claude/agents/p19-front.md" ;;
		param) printf '%s' "$T" >"$S/policy/pretool-agent-cwd" ;;
		hook) jq -nc --arg d "$T" '{hookSpecificOutput: {hookEventName: "SubagentStart", cwd: $d, workingDirectory: $d}}' >"$S/policy/out-SubagentStart" ;;
		esac
		if [ "$c" = main ]; then
			prompt="First, with the EnterWorktree tool (load it with ToolSearch if needed), pass path $T (and no name); this probe needs the worktree. Then run the Bash command pwd. Then start one agent $BGP, subagent_type \"p19-main\", prompt \"go\". $WAIT Include its final answer and what EnterWorktree returned."
		elif [ "$c" = iso ]; then
			prompt="Start one agent $BGP, with isolation: \"worktree\", subagent_type \"p19-iso\", prompt \"go\". $WAIT Include its final answer."
		else
			prompt="Start one agent $BGP, subagent_type \"p19-$c\", prompt \"go\". $WAIT Include its final answer."
		fi ;;
	P19bc)
		STEP1=pwd mkagent p19-cd '' "Run each as one Bash command, exactly as written:
2. cd $T && sh tests/run.sh
3. cd $T && make test
4. cd $T && git status
Controls:
5. sh tests/run.sh
6. make test
7. git -C $T status
$ON"
		prompt="Start one agent $BGP, subagent_type \"p19-cd\", prompt \"go\". $WAIT Include its final answer." ;;
	esac
	mv "$S/.claude" "$R/.claude"; CLDIR="$R/.claude" MAIN_DIR="$R" PERM=default
	case $1 in *-bypass) PERM=bypassPermissions ;; esac
	main "$prompt" 300
	{ find "$R" "$T" -name 'p19-rel-*'; } >"$K/logs/$1/files-after.txt" 2>&1 ;;
P2c-key)
	P=${PN:-P2c}; S="$SB/$P"; shift
	printf '%s keys %s\n' "$(date +%s)" "$*" >>"$S/logs/keys.txt"
	tmux send-keys -t stop-hook-probe-p2c "$@"; sleep 2
	tmux capture-pane -p -t stop-hook-probe-p2c | tee -a "$S/logs/panes.txt" | grep -v '^ *$' | tail -20 ;;
P2c-end)
	P=${PN:-P2c}; S="$SB/$P"
	if [ -d "$S/repo/.claude" ]; then CLDIR="$S/repo/.claude" MAIN_DIR="$S/repo"; fi
	tmux capture-pane -p -t stop-hook-probe-p2c >>"$S/logs/panes.txt"
	tmux send-keys -t stop-hook-probe-p2c C-c; sleep 1; tmux send-keys -t stop-hook-probe-p2c C-c; sleep 8
	tmux kill-session -t stop-hook-probe-p2c 2>/dev/null || true
	collect ;;
all)
	for p in P1 P1c P2a P2b P2d P2k P2e P3 P4 P5 P6 P6t P6q P7 P8 P9 P10a P10b-turns P10b-err P12 P12s P13a P13a-proc P13a-ctl P13a-ctl700 P13b P13c P14 P14d P15n P15a P15c P16a P16a-dirs P16a-bypass P16c P16c-in P16d-set-default P16d-set-acceptEdits P16d-add-default P16d-add-acceptEdits P17a P17c-default P17c-acceptEdits P17c-bypassPermissions P17d-edit P17d-both P18 P19-schema P19a-front P19a-param P19a-hook P19a-enter P19a-main P19a-enter-allow P19a-main-allow P19a-enter-bypass P19a-main-bypass P19a-iso-bypass P19bc; do sh "$0" "$p"; done ;;
*) echo 'usage: run.sh P1|P1c|P2a|P2b|P2d|P2k|P2e|P3|P4|P5|P6|P6t|P6q|P7|P8|P9|P10a|P10b-turns|P10b-err|P12|P12s|P13a|P13a-proc|P13a-ctl|P13a-ctl700|P13b|P13c|P14|P14d|P15n|P15a|P15c|P16a|P16a-dirs|P16a-bypass|P16c|P16c-in|P16d-set-default|P16d-set-acceptEdits|P16d-add-default|P16d-add-acceptEdits|P16b|P17a|P17b|P17c-default|P17c-acceptEdits|P17c-bypassPermissions|P17d-edit|P17d-both|P18|P19-schema|P19a-front|P19a-param|P19a-hook|P19a-enter|P19a-main|P19a-enter-allow|P19a-main-allow|P19a-enter-bypass|P19a-main-bypass|P19a-iso-bypass|P19bc|all' >&2; exit 2 ;;
esac
