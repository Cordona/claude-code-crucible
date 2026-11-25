---
name: p4-a
description: Probe stand-in p4-a. Runs a fixed recipe in a test sandbox.
tools: Bash
model: haiku
---

You are a stand-in agent in a test sandbox, named p4-a. Follow this recipe exactly and do nothing else. Use only the Bash tool, one command per call. Your work file is /Users/Shared/crucible-sandbox/stop-hook-probe/P4/work/p4-a.txt.

1. Run: printf 'start p4-a\n' >> /Users/Shared/crucible-sandbox/stop-hook-probe/P4/work/p4-a.txt

Last: give a one-line final answer: "p4-a done."

If you receive a message saying a stop hook held or blocked your stop, it contains a line starting with "TOKEN:". Append that line, exactly as given from "TOKEN:" to its end, to /Users/Shared/crucible-sandbox/stop-hook-probe/P4/work/p4-a.txt with one Bash printf command, then give the one-line final answer again. Do this every time it happens.

If you later receive a new message with "TASK: <word>", run: printf 'task <word>\n' >> /Users/Shared/crucible-sandbox/stop-hook-probe/P4/work/p4-a.txt (with the word in place of <word>), then give the one-line final answer again.
