# 05 · Workflow clarity (WF)

Purpose: the agent follows the procedure step by step, knows when a step failed, and knows when to stop.
Judges steps, checks, loops, freedom per step, human gates and the closing report.

**Applies when:** flows and procedures with two or more steps; standards and plugins: WF-03, WF-05, WF-06, WF-10 only.
**MUST lint:** LNT-73.

**Levels.** Each item takes the level of the heading above it.

## MUST

- **WF-04** · Does every agent or script retry loop have a hard cap, a progress test (what must change between rounds) and an outcome at the cap (escalate, never approve), and every human-gated loop an explicit exit option? A loop without them repeats the same failing round, or approves to end it. · Check: list every loop, including validation retries. · Fix: add "cap N; at the cap report as an escalation", or the exit option.
- **WF-10** · Is there no nested numbered list, with each sub-step on its own line numbered `N.1`, `N.2` and its cases as plain `-` bullets? Markdown renders a nested numbered item as i, ii or a, b, so the number the reader sees is not the one written. · Check: lint LNT-73. · Fix: renumber each nested item as `N.1`, `N.2` on its own line; turn its cases into `-` bullets.

## SHOULD

- **WF-01** · Is a multi-step procedure laid out as numbered steps, with a copyable checklist or todo instruction when it has five or more steps or a loop? Without numbered steps the agent skips or merges a step and nothing shows it. · Check: read. · Fix: number the steps; add "copy this checklist into your reply and tick it off".
- **WF-02** · Can each check step actually fail, and does it name the step to return to? A check that cannot fail passes every run, and a failed check with no return step leaves the agent to improvise. · Check: yes if every check has "on fail → step N". · Fix: add the failure condition and the return line.
- **WF-03** · Does each quality-critical output have a validate → fix → repeat loop against a named validator (script or short checklist), noting each issue with the rule it breaks and finishing only when all pass — for a standard, a short self-check list (≤ 7 items) the builder runs before reporting done? Without a named validator the first draft's defects ship unseen. · Check: read. · Fix: add the loop or the self-check list.
- **WF-05** · Is each step's freedom matched to its fragility — exact commands for steps where a deviation corrupts state, loses data or bypasses a gate; goals and heuristics elsewhere? · Check: yes if no fragile step is a heuristic and no open step is scripted word for word. · Fix: lock fragile steps to a command or script; loosen open ones.
- **WF-06** · Are (a) branch points explicit (condition → step), (b) required-shape outputs templated with stated strictness, and (c) style-dependent outputs shown by an input → output or good/bad example? Without them the agent picks a branch at random and each run invents its own output shape. · Check: report FAIL(a|b|c) per missing part. · Fix: add the branch line, the template, or one example pair.
- **WF-07** · Does each human gate show the exact proposal, use one AskUserQuestion call (several questions inside are fine) with the recommended option first and facts per option, skip what was already answered, and state the action per answer? A gate that hides the proposal gets an approval of something the human never saw. · Check: read each gate. · Fix: rewrite the gate to that shape.
- **WF-08** · In an unattended run, does the skill never end its turn to wait, and send notices with the next tool call? An ended turn in an unattended run waits for an answer nobody gives. · Check: N/A for gated flows. · Fix: replace the wait with a rule-based decision.
- **WF-09** · Does the closing report give counts, why the loop ended and each seat's verdict verbatim, and does a hand-off to a sibling skill pass a restated brief? Without them the human can't tell a clean run from a cut-off one. · Check: read the summary and hand-off steps. · Fix: add the counts and quoted verdicts; restate the brief at hand-off.
