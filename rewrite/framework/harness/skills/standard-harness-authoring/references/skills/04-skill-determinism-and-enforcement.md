# 04 · Determinism and enforcement (DET)

Purpose: decisions that must not vary are made by scripts and gates, restrictions last as long as needed, and the skill fails closed.
Judges what is scripted, outcome handling, state and recovery, and turn-scoped frontmatter fields. Hook mechanics are in 10.

**Applies when:** flows and procedures; standards: DET-08 and DET-09 only. DET-08 is N/A for a standard that ships no script: only agents preload it, so its hook belongs to the binding agent and is judged there (agent-02, agent-07).
**MUST lint:** LNT-31.

**Levels.** Each item takes the level of the heading above it.

## MUST

- **DET-02** · Does every script call have a next step for success, for each documented failure outcome, and for "any other output"? · Check: table each call's outcomes against the text. · Fix: document the outcome set and add the missing next steps.
- **DET-03** · Does the skill fail closed — an unexpected error, missing tool, unparseable output or unavailable capability stops and reports, and another path is taken only if the skill documents it (capability check → stated fallback, each tried once)? · Check: trace each script call and required tool. · Fix: add "on any other result: stop and report it verbatim"; document any fallback.
- **DET-09** · Does the skill avoid relying on `allowed-tools`, `disallowed-tools` or `model` beyond the invoking turn? · Check: they last only until the next user message (and `allowed-tools` is ignored under `allowManagedPermissionRulesOnly`); yes if no step after a human gate or later message depends on them. · Fix: put a tool-level restriction in agent `tools`/`disallowedTools` (`Bash(pattern)` there restricts no command); put any other lasting restriction in a permission deny rule, or in a PreToolUse hook only when a deny pattern can't express it; re-invoke the skill to re-apply a grant.
- **DET-10** · Do `!` injected commands stay valid: `|| true` where non-zero is expected, absolute or `${CLAUDE_SKILL_DIR}` paths, fast (a timeout aborts the invocation; its length is in the frontmatter-fields Versions table), quiet on stderr (merged into the text), with stated behavior when shell execution is disabled? · Check: judge beyond LNT-31 (pre-approval). · Fix: add `|| true`, absolute paths, `2>/dev/null` where noise is expected, and the fallback note.

## SHOULD

- **DET-01** · Is every mechanical decision — inputs are files or counts, outcome is a fixed vocabulary (caps, verdicts, status transitions, dates, ids, digests, renders shown for approval) — computed by a script? · Check: list the skill's mechanical decisions; yes if each names its script or a rule-owning skill's fixed arithmetic. · Fix: move the decision into a script; the skill acts on its output.
- **DET-04** · Are counters, statuses and ids owned by a script or state file, stable across iterations, and are records later steps rely on append-only (a correction is a new retracting entry)? · Check: yes if no counter lives only in the model's memory. · Fix: persist it in the state file or let the script compute it.
- **DET-05** · Do operations that delete, write outside the scratch area, or act on more than one target follow plan → validate by script → execute → verify? · Check: yes if a plan file is validated before execution and the result verified after. · Fix: write the plan to a file, add a validator, execute only on a pass.
- **DET-06** · Does a multi-step flow persist its step and counters to a file outside the repo after every step, and does its resume rule re-invoke the skill (also after compaction), verify inputs match, skip completed steps and keep the recorded settings? · Check: read the state and resume text. · Fix: add the state file and a resume section that starts "re-invoke this skill first".
- **DET-07** · Is state and external data read live from its source (script, tool, file), never from memory or earlier turns, with a failed read shown as unknown or stale, never zero? · Check: yes if every input names its live source and its failure display. · Fix: name the command that reads it; show `?`/stale on failure.
- **DET-08** · Is every rule whose single violation is costly and observable by a script or tool call enforced by a script refusal or a hook — chosen selectively, the few highest-cost rules — with the prose as its explanation? · Check: list the skill's few highest-cost observable rules; yes if each has a refusal or hook. · Fix: add the refusal to the script, or a hook (10).
