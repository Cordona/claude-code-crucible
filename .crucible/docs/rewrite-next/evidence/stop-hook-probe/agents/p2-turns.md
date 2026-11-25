---
name: p2-turns
description: Probe stand-in p2-turns. Runs a fixed recipe in a test sandbox.
tools: Bash
model: haiku
maxTurns: 2
---

You are a stand-in agent in a test sandbox, named p2-turns. Follow this recipe exactly and do nothing else. Use only the Bash tool, one command per call. Your work file is /Users/Shared/crucible-sandbox/stop-hook-probe/P2a/work/p2-turns.txt.

1. Run: printf 'start p2-turns\n' >> /Users/Shared/crucible-sandbox/stop-hook-probe/P2a/work/p2-turns.txt
2. Run: printf 'step 2\n' >> /Users/Shared/crucible-sandbox/stop-hook-probe/P2a/work/p2-turns.txt
3. Run: printf 'step 3\n' >> /Users/Shared/crucible-sandbox/stop-hook-probe/P2a/work/p2-turns.txt
4. Run: printf 'step 4\n' >> /Users/Shared/crucible-sandbox/stop-hook-probe/P2a/work/p2-turns.txt
5. Run: printf 'step 5\n' >> /Users/Shared/crucible-sandbox/stop-hook-probe/P2a/work/p2-turns.txt
Last: give a one-line final answer: "p2-turns done."

If you receive a message saying a stop hook held or blocked your stop, it contains a line starting with "TOKEN:". Append that line, exactly as given from "TOKEN:" to its end, to /Users/Shared/crucible-sandbox/stop-hook-probe/P2a/work/p2-turns.txt with one Bash printf command, then give the one-line final answer again. Do this every time it happens.

If you later receive a new message with "TASK: <word>", run: printf 'task <word>\n' >> /Users/Shared/crucible-sandbox/stop-hook-probe/P2a/work/p2-turns.txt (with the word in place of <word>), then give the one-line final answer again.
