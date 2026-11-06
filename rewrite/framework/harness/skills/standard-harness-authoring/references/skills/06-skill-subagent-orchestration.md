# 06 · Subagent orchestration (SUB)

Purpose: dispatched seats get everything they need, judge independently, and return output the orchestrator can branch on.
Judges briefs, seat choice, output contracts, failure policy, file ownership and forks. Agent files: `references/agents/` (agent-01–08).

**Applies when:** the skill dispatches subagents (Agent tool or `context: fork`).
**MUST lint:** LNT-35, LNT-36.

**Levels.** Each item takes the level of the heading above it.

## MUST

- **SUB-02** · Is every brief self-contained — paths, scope, prior results it builds on, and the rules the seat must obey, cited by skill + § only when the seat preloads that skill and restated otherwise? · Check: read each brief as a stranger. · Context: the seat agent's `skills:` list. · Fix: add the missing input; restate rules from skills the seat does not preload.
- **SUB-06** · Is each seat named explicitly by rule (step or round number, not the orchestrator's sense of progress), as `<plugin>:<agent>` for plugin agents, with no per-dispatch `model`, and does a missing seat stop the flow with instructions? · Check: read. · Fix: name the agent per step; add "if the agent is missing, stop and say how to install it".
- **SUB-11** · With `context: fork`, does the skill have an explicit task, standalone instructions, `agent` set, and a `background` value justified by the tool set it needs (background has fewer tools and its edits bypass `/rewind`)? · Check: N/A without `context: fork`. · Fix: give the fork a task or drop `context: fork`; set `background: false` when it needs full tools.
- **SUB-12** · Does every brief fence untrusted data (repository text, web pages, another seat's output) in named tags, and strip or escape those tags' markers inside the data, so the data can't close the fence? The human's own words (their notes and request) and the text of plugins the human installed are trusted: a brief or hook-built message whose embedded data comes only from them needs no marker-stripping, when the skill states this. · Check: read how each brief embeds data; a brief that skips stripping needs that statement. · Fix: wrap data in `<untrusted-…>` tags; remove the marker strings from the data before embedding.
- **SUB-14** · Is a seat that failed or returned nothing recorded as unverified or not run, never dropped and never shown as confirmed? · Check: read the merge step's handling of an empty or failed return. · Fix: record it as `unverified` and show it to the human.

## SHOULD

- **SUB-01** · Does the orchestrator do only protocol work — gate recommendations and mechanical assembly of seat output (merges, renders, plan revisions) included — with every grading, reviewing or authoring of domain content sent to a seat? · Check: read each orchestrator step. · Fix: move the domain step into a seat's brief.
- **SUB-03** · Is each brief a template in the skill with a fixed header (step, files to read, files to write, output format), only slots substituted, no hints or pre-judgment, and an honesty clause (a marked gap beats a papered-over one)? · Check: a chat-reply cap is allowed only when the full report is in a file; the number of findings is never capped. · Fix: convert the prose brief to a slotted template.
- **SUB-04** · Does the brief pass canonical inputs by path (shell-spliced when a copy is needed), never paraphrased, and tell seats to reread a source before relying on it? · Check: read. · Fix: replace the summary with the path and a one-line hint.
- **SUB-05** · Does each judging step use a fresh dispatch (new instance), with the same reviewer type re-reviewing its own findings passed back by id, a different type only for a re-check or adversary role, and parallel seats genuinely different or deliberate replicas? · Check: read the dispatch rules. · Fix: dispatch a new instance per round and pass prior findings by id.
- **SUB-07** · Does each seat return (a) a fixed contract — first-line verdict or schema — the orchestrator branches on, (b) detail in a file, (c) completion shown by existence, end line or script, (d) output screened for empty, refusal or off-topic, and (e) a final deliverable with no run-file references? · Check: report FAIL(a–e) per missing part. · Fix: define the contract; check `test -s` + end line; screen; grep the deliverable for run paths.
- **SUB-08** · Do long-running seats write their plan and intermediate results to their output file as they go, and does a failure policy re-run an unfinished seat once with its partial output, stop after a repeat or wave-wide failure, and say how to resume? · Check: read. · Fix: add incremental-write and end-line rules to the brief; add the re-run-once, stop and resume lines.
- **SUB-09** · Does the skill state which files the orchestrator and each seat may write (state, notes, index), and save a draft before a seat rewrites it? · Check: read. · Fix: add an ownership list; copy the draft to `<name>_previous` first.
- **SUB-10** · Are independent dispatches sent in one message, with foreground or background stated? · Check: read. · Fix: "dispatch all N in one message"; state whether to wait.
- **SUB-13** · Does a fan-out have a total dispatch budget and a stall limit, keep headroom for later phases, and report any work it skipped? · Check: read the fan-out step. · Fix: cap the dispatches; reserve a share for later phases; list skipped work in the result.
