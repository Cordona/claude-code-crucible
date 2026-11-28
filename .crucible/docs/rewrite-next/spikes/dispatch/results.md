# Spike: dispatching a job agent (results)

2026-11-26. Claude Code 2.1.332. Opus 5.5 main (headless `claude -p`, permission mode default, allow-list by `--settings`), stand-in agents on Haiku. Built on the real install: real effort, tree, event writer and rules, the real SubagentStop hook and the job-agent-tools PreToolUse hook. The spike adds only `kit/agent-dispatch/` (the door, the checks, the prompt builder, two hooks) and two folder-only agents. `new-rewrite/` was not changed. Design: `design.md`; Fable's review: `../../reports/dispatch-spike-design-fable.md`.

## Verdict

The mechanism works. A job agent is started from `Job N` alone, gets a script-built prompt byte for byte, is tied to its job before its first tool call, and hands in through the real stop hook. Main repaired every refusal from the lines alone, and a folder-only agent worked with no dispatch code change.

## Spikes

| # | Result | Fact |
|---|---|---|
| S1 | PASS | Opus main dispatched and started `Job 3`. The agent received the built prompt byte for byte (17,550 bytes, plugins included). `job.assigned` was written by the hook, and `echo.submitted` came from the real stop hook. No lab assignment. |
| S2 | PASS | Main started echo-reviewer with its own prose. It was denied with the reason naming the door, then main read `--help`, dispatched and started `Job 3`, unsteered. The prompt was byte-equal (17,548). Interactive too (S2i): the deny shows on screen as `Error: PreToolUse:Agent hook error: <reason>`. |
| S3 | PASS | No lens given. Refused with `an echo job needs a lens, clarity or correctness: add --lens …`, plus a wrong kind. Main fixed both from the lines and the job was written. Byte-equal (25,945). |
| S4 | PASS | `doc-writer` added as a folder only: definition, `job-check.jq`, `plugins.json`, `submissions/doc.json`, a report rule and `events/doc.submitted.jq`. The dispatch code's hashes were equal before and after (`evidence/dispatch-code-before-S4.sha`). Dispatched first time, byte-equal (21,346), `doc.submitted` from the real stop hook. Link chain: `evidence/S4-links.txt`. |
| S5 | PASS | 3 Agent calls in one message, each bound to its own job (3, 4, 5), and 3 assignments. A hot follow-up via SendMessage `Job 12` to the first agent was swapped, assigned and submitted. The resumed agent got the built text, byte for byte, inside Claude Code's wrapper (see below). |
| S6 | recorded, as Fable expected | Two calls named Job 3. Both passed resolve-job, since nothing is written before the call. The first got `job.assigned`; the second's assignment was refused by the real rule (assigned once), so no event. The second agent's report write was denied, and at its stop the real hook told the human: `crucible: agent … (echo-reviewer) stopped, and no effort has a job assigned to it; its report, if any, was not checked or handed in`. The first job ended normally. |
| S7 | PASS | A general-purpose Agent call and a SendMessage to it passed untouched: no hook output, no event. |
| S8 | recorded | SendMessage "How is it going?" to an agent mid-job: the hook saw a job agent and no `Job N`, let it through and noted it. Claude Code queued it ("delivered … at its next tool round"), and the agent got it as `The coordinator sent a message while you were working: … Address this before completing your current task.` |
| S9 | recorded: no start folder | A `cwd: <tree>` added by `updatedInput` was accepted silently and ignored; the agent's `pwd` was main's folder (the repo). The fields main sent were description, prompt, subagent_type and run_in_background. Only `isolation: worktree` exists, and that cuts Claude Code's own worktree. So `cd <tree> && …` stays a prose or allow-list matter. |
| S10 | PASS | Full effort: context v2 (the latest of two cuts), 2 grills, an approved 8-part spec, plugin texts. Prompt 19,999 bytes, byte-equal. |

S1's first run (`evidence/S1-run1/`) also passed, but main invented `--language markdown --standard clarity`. Those weren't installed, so the prompt silently had no plugin text. That's kit bug 1 below, fixed and rerun.

## Free records

- **The assignment moment:** SubagentStart and PostToolUse(Agent) fire in the same millisecond, right after launch. The assignment write ended 0.43–1.07 s before the agent's first tool call in 13 of 13 agents (`evidence/timing.txt`). The write guard never denied a first write of an assigned agent.
- **Hooks of parallel calls:** they run nearly in turn, with each call's PreToolUse about 0.5 s after the last. A call's PostToolUse can overlap the next call's PreToolUse (S6: assign 1 ran from .083 to .609 while guard 2 started at .159). That's why both S6 calls resolved to the same job.
- **Payloads:**
  - PreToolUse(Agent): `tool_input {description, prompt, subagent_type, run_in_background?}`, plus `session_id` and `tool_use_id`.
  - PostToolUse(Agent): `tool_response.agentId`.
  - SendMessage: `tool_input {to, message, content, summary, type, recipient, recipient_kind}`, so `message` and `content` both carry the text. The swap of `message` alone reached the agent; a real hook should set both.
- **Hot delivery wrapper:** a SendMessage arrives as `The coordinator sent a message while you were working:\n<text>\n\nAddress this before completing your current task.`
- **Permission prompt (interactive):** the Agent tool never prompted in default mode, so the human doesn't see the swapped prompt at a prompt. The screen shows the agent's description only.
- **The deny text main sees:** `PreToolUse:Agent hook error: <reason>`. Main followed it both times it was shown (S2, S2i).
- **Hook times:** guard plus assign took 0.10–1.30 s, median 0.50 s (32 calls, under parallel load).
- **Main's repairs:** every echo-reviewer run refused once or twice before the job was written:
  - kind `review` → `echo` in 9 of 9 runs, plus S2i;
  - invented plugins `markdown`/`clarity` in 4 runs after the fix, and silently accepted in S1's first run;
  - a missing lens in S3.

  The doc-writer job was written first time. Each refusal was fixed from the lines alone, with at most 3 dispatch calls per job.

## Kit bugs fixed

1. **No plugin check:** an unknown language or standard was accepted and its plugin text silently dropped. Added `setup-check.sh`, the check every job gets whatever its agent, which runs before the agent's own check. Repair lines list the installed plugins. S1 was rerun after the fix.
2. **PATH quoting in the interactive launcher:** the path had a space in it. Fixed; kit only.

## What changes the design

1. **Grills have no slot in `job.dispatched`.** The spike put every ended grill in the prompt. If a job should name its grills, the event needs a field.
2. **Kinds aren't discoverable.** Main guessed `review` in every echo-reviewer run (9 of 9, plus S2i). The door's help, or the refusal, should list the agent's kinds, or the agent's folder should say which kinds it takes.
3. **Refusals come one layer at a time:** setup check, then job check, then the generic rule. Running all of them and printing every line at once would save a round.
4. **Two calls on one job (S6):** the second agent runs without a job until its stop. Either accept that, since the human is told at the stop and nothing was handed in, or let the assignment step tell the human at once.
5. **The swap must set SendMessage's `content` too,** not just `message`.
6. **The start folder can't be set through the Agent call** (S9).
7. **`job.dispatched` is written by `job-write.sh` under the writer name `job-dispatch.sh`,** because the real rule pins that name. Naming the writer is the spec's call.
8. **`Job N` alone is ambiguous across efforts.** The spike bound it to jobs dispatched in the same Claude Code session. That held in every run, but the spec should say so.

## Evidence and rerun

- **Evidence:** `evidence/<S#>/`, each with:
  - main's stream (`main.jsonl`), the prompt and the settings;
  - `hooks/`, every hook call with its input, output and timing;
  - `timeline.tsv`;
  - `efforts/*/events.json` and the reports;
  - `transcripts/`, the sub-agent transcripts (raw: keep them out of any commit);
  - `built-N.txt` and `received-N.txt`, the equality pairs.
- **Interactive:** `evidence/S2i/screen.txt`.
- **Rerun:**
  1. `kit/run.sh setup`;
  2. `kit/run.sh effort <name> [full]`;
  3. `kit/run.sh session S` and write its `prompt.txt`;
  4. `kit/run.sh main S <prompt>`;
  5. `kit/collect.sh S <effort>`, `kit/show.sh S` and `kit/equal.sh S <effort> <job>`;
  6. `kit/run.sh unlink` to remove the links (done).
- **Sandbox:** `/Users/Shared/crucible-sandbox/dispatch-spike/`. The sandbox config's `.claude.json` got the repo's trust entry, and its earlier copy is in `run/claude.json.before`.
