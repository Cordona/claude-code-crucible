# Step details

Detail the flow's `SKILL.md` needs at one step only. Read each section when that step names it; the rules in `SKILL.md` still bind.

## Contents

- Script exits: after every `lint.sh` or `merge-verdicts.sh` run
- Run files: at Start step 2 and on Resume
- Resume: after a compaction, an interruption or a new session
- Dispatch budget: before each wave of dispatches
- Explain: Skill flow step 1, refactor
- Script builds: Skill flow step 3
- Deploy: G4
- Run and grade: Skill flow step 6, Agent flow step 6
- Closing report: the flow's last step

## Script exits

Output lines that go to G3:

- `lint.sh`, whatever its exit: each `FAIL` line with a `SHOULD:` or `MAY:` prefix and each `WARN` line.
- `merge-verdicts.sh`: every output line the rulebook's Script reference lists, except `dropped-duplicate:`.

| Exit | `lint.sh` | `merge-verdicts.sh` |
|---|---|---|
| 0 | Seat the swarm (on a re-check, only the seats Merging step 5 names) | PASS → Merging step 4 when anything is listed for G3; else the flow's next step |
| 1 | Back to the author (FIX, with the lint output) | BLOCKED → Merging step 4 |
| 3 | As exit 0; tell the owner which `MUST` items it skipped | Re-dispatch the malformed seat (stderr names it) once; a second exit 3 for it: report the seat to the owner as missing at G3, never as passed |
| 2, 4 | Usage error (2), rulebook not found (4): stop; show the owner stdout and stderr verbatim | As `lint.sh` |
| 5 | A required tool is missing (stderr names it) or an internal error: stop; show the owner stderr verbatim | As `lint.sh` |
| 130, 143 | Interrupted (INT, TERM): stop and tell the owner; Resume runs the step again | As `lint.sh` |
| other | Stop; show the owner stdout and stderr verbatim | As `lint.sh` |

## Run files

| File | Holds | Written by |
|---|---|---|
| `state.md` | What `SKILL.md` (Run files) lists | orchestrator, after every step |
| `explanation.md`, `verify.md` | Skill refactor: the analyst's explanation and its check | orchestrator, from the replies |
| `spec.md` | New skill or agent: the approved spec | orchestrator, with the owner |
| `change-request.md` | Agent refactor: the approved change request | orchestrator, with the owner |
| `decisions.md` | The owner's decisions, one entry each: `D<n> · <date> · <gate or step> · <item ID or none> · "<owner's words>"`; a CONFORMANCE `CHANGED` cites `decision D<n>` | orchestrator |
| `snapshot/` (skill), `snapshot.md` (agent) | Refactor: the old version, the baseline for Run and grade; not taken when the old skill stays in place (its path is the baseline) | orchestrator |
| `author-report.md` | The author's report | `skill-author` writes it; for `agent-author`, the orchestrator saves the reply |
| `lint/round-<n>.txt` | `lint.sh` output | orchestrator |
| `review/<seat>.md`, `review-r<n>.md` | Each seat's reply; each round's merged report, never overwritten | orchestrator |
| `scripts/<script>-r<n>.md` | `shell-script-developer`'s report for each build or fix round | orchestrator, from the reply |
| `runs/` | Run outputs and grades (transcripts are not saved: a subagent's transcript can't be read back, so the output file is the evidence) | orchestrator |
| `pre-fix/explain-r<n>/`, `pre-fix/script-<script>-r<n>/`, `pre-fix/fix-r<n>/` | Copies taken before each loop's fix (`SKILL.md`, Run files) | orchestrator |

## Resume

1. Read `<run dir>/state.md`; ask the owner for the run dir if the conversation no longer names it.
2. Check that the target and every run file it names exist and match it. A mismatch: stop and show the owner.
3. Skip the steps it marks done, keep its run inputs and counters, and continue from its current step.

## Dispatch budget

- **Budget:** at most 3 × (S + 3E + P + 3) dispatches per run, with S the swarm's seats, E the approved evals (two arms and a grader each), P the script specs, and 3 for analysts and the author; the 3 × covers the round cap.
- **Reserve:** before Run and grade has run, keep 3E of the budget for it.
- Before each wave, add its size to the dispatch count in `state.md`; a wave that would exceed the budget is handled as `SKILL.md`'s Every dispatch says.

## Explain

1. Dispatch `skill-analyst` in `EXPLAIN` mode; save the reply as `explanation.md`.
2. Dispatch a second `skill-analyst` in `VERIFY` mode with that path; save the reply as `verify.md`.
3. On a missing card, or a `WRONG LINE` or `UNSUPPORTED` on a rule card's rule, source or enforcement: copy both files to `pre-fix/explain-r<n>/` (also before a G1 *Re-explain*), dispatch `skill-analyst` in `EXPLAIN` again with the correction brief (the old explanation and `verify.md`), save the reply as `explanation.md`, and give it its own `VERIFY` into `verify.md`. That is the loop: one `EXPLAIN`, one `VERIFY`, and at most one correction, which gets its own `VERIFY`. Any other `WRONG LINE` or `UNSUPPORTED` (a citation or claim that changes no card) goes to G1 as found, with no correction.
4. Add one line at the top of `explanation.md` naming the last `verify.md` and its counts.

## Script builds

1. Each script spec in `skill-author`'s report (§3) must name its live-validation targets, the real files to run it against. One that names none goes back to `skill-author` (FIX); when that reply returns, repeat this check on the new report before step 2. A spec that still names none stops the loop (`SKILL.md` Invariants: a loop with no progress).
2. Dispatch `shell-script-developer` once per script spec, all in one message; each builds its script and live-validates it against real files, with no tests and no review. Save each reply as `scripts/<script>-r<n>.md`.
3. A Validation field showing a failed or skipped live run: copy the script and that report to `pre-fix/script-<script>-r<n>/`, then send it back to `shell-script-developer` in a fix round with that report.
4. A fix round whose Validation field shows the same failing command and output as the round before stops early and goes to the owner with both reports. After the script's round 3, stop and show the owner the last report.

## Deploy

1. **Before asking:** Grep the target's files for the run root and waivers dir paths. A hit goes back to the author as a FIX, then Skill flow step 5 or Agent flow step 4; no G4 yet.
2. The link path is `~/.claude/skills/<name>` (skill) or `~/.claude/agents/<name>.md` (agent). Run `ls -ld <link path>` and, if it exists, `readlink <link path>`. A link that already prints the target path needs no G4: tell the owner it is deployed.
3. **Deploy now:** `ln -s <target dir or agent file> <link path>`, never with `-f`.
4. **Replace the link:** `rm <link path>`; a non-zero exit: stop and show the owner its output verbatim, with no `ln -s`. Otherwise the `ln -s` of item 3.
5. **After `ln -s`:** `readlink <link path>` must print the source path. Any non-zero exit or a mismatch: stop and show the owner the output verbatim.

## Run and grade

1. Give each approved eval an id (`E1`, `E2`, …).
2. Dispatch both arms of every eval in one message, each a fresh subagent with the run-arm brief. The skill arms and the agent baseline are `general-purpose`; the agent new arm is a real dispatch of the agent under test. The new arm uses the target; the baseline uses nothing (new; `baseline: none`) or the snapshot, or the old skill's own path when no snapshot was taken (refactor; `baseline: old version`).
3. Save each output as `runs/<id>-new.md` and `runs/<id>-base.md` (an empty file when a run returned nothing).
4. Dispatch `eval-grader` once per eval, all in one message; save each grade as `runs/<id>-grade.md`.
5. Show the owner the outputs beside the grades, then G3. Their feedback, each failed outcome, and each outcome the baseline also passes go back to the author in `FIX` mode with the chosen run outputs and grades. Then re-run only the evals with a chosen FAIL.

## Closing report

One message to the owner, holding:

- the files written, by path;
- each seat's last VERDICT line, verbatim, and `merge-verdicts.sh`'s last VERDICT line;
- the findings fixed, waived and still open, by ID;
- each eval's grade per outcome, new arm and baseline;
- each seat or eval not run, and why (cut off, refused, or over the dispatch budget);
- how many rounds ran and why the loop ended (all pass, the owner stopped, unchanged, or escalated after round 3);
- what still needs the owner: the commit, and the deploy if G4 said not yet.
