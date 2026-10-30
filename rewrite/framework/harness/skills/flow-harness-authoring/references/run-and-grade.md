# Run and grade

How the approved evals are run and graded, read when Skill flow or Agent flow step 6 is reached.

1. Give each approved eval an id (`E1`, `E2`, …).
2. Dispatch both arms of every eval in one message, each a fresh subagent with the run-arm brief. The skill arms and the agent baseline are `general-purpose`; the agent new arm is a real dispatch of the agent under test. The new arm uses the target; the baseline uses nothing (new; `baseline: none`) or the snapshot, or the old skill's own path when no snapshot was taken (refactor or change; `baseline: old version`).
3. Save each output to `runs/<id>-new.md` and `runs/<id>-base.md` with `save-reply.sh --whole` (an empty file when a run returned nothing).
4. Dispatch `eval-grader` once per eval, all in one message; save each grade as `runs/<id>-grade.md`.
5. Seat checklist 08 with the run outputs and grades (`SKILL.md` Reviewer swarm, which names its brief): one `skill-reviewer` CHECKLIST seat on 08 for a skill target that gets one, or, for an agent target, the `agent-reviewer` seat holding agent-08 again. Save it as Merging step 1 sets, and merge again over every seat's latest report (Merging step 3).
6. Ask G3; `--paths` lists the run outputs. The human's feedback, each failed outcome, and each outcome the baseline also passes go back to the author in `FIX` mode with the chosen run outputs and grades. Then re-run only the evals with a chosen FAIL, and step 5 again.
