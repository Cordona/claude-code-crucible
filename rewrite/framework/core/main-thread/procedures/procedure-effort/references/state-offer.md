# Offering a state change

SKILL.md step 10: offer to pause, complete or drop the open effort. Read when step 10's trigger holds (SKILL.md When to use it): case `done` when every part is done, case `new-work` when the human moved to work the effort doesn't cover.

10.1 **Hold the offer** only when SKILL.md Never holds it: go on with the work and offer nothing. Otherwise offer.

10.2 **Write the reasons** to the plan file `procedure-approval-gate` gives, in the shape `render-effort-offer.sh --help` sets: what you saw, one reason per line. In either case, never write a path or a recap of earlier runs; for secrets, SKILL.md Never sets the rule. In case `done`, state only that every part of the effort is done. In case `new-work`, Good: "The new request is a docs change the prune effort doesn't cover". Bad: "Something new came up" (says nothing the human can weigh).

10.3 **Offer it** through `procedure-approval-gate`, loaded with the Skill tool, following its steps with these inputs:
- **The renderer:** `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/render-effort-offer.sh" --plan-file '<the plan file>' --case done|new-work --name '<name>'`, with no `--open-effort`, the case as read above.
- **The gate's label:** `effort-state-offer`, with no `--effort`.
- **On "now ask":** Read the question for the case: case `done`, `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/state-offer-done-question.json` (it recommends Complete, as the `done` view does); case `new-work`, `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/state-offer-question.json`; ask it as SKILL.md step 1 asks the offer's question.
- **The offer can't be shown or asked:** change nothing, go on with the work, and treat it as "Keep going".

10.4 **Act on the answer:**
- **"Keep going":** nothing is written; go on with the work.
- **"Pause", "Complete", "Complete (Recommended)" or "Drop":** Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/state-change.md` and follow it from step 9.2, with this effort's folder.
- **A typed answer:** a reply: answer it, and change nothing.
- Then, in case `new-work`: the new request goes by CLAUDE.md §4, which may offer it its own effort (SKILL.md step 1); that offer's renderer adds `--after-state-offer`.
