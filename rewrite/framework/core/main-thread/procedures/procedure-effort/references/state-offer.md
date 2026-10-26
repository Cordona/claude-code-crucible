# Offering a state change

SKILL.md step 10, which offers to pause, complete or drop the open effort; read at step 10, when its work looks done (a flow may load step 10 after its run summary: case `done`, the effort the flow runs in) or the human moves to work it doesn't cover.

10.1 **Hold the offer** when SKILL.md Never holds it: go on with the work and offer nothing.

10.2 **Write the reasons** to the plan file `procedure-approval-gate` gives, in the shape `render-effort-offer.sh --help` sets: what you saw, one reason per line, never a path or a secret.

10.3 **Offer it** through `procedure-approval-gate`, loaded with the Skill tool, following its steps with these inputs:
- **The renderer:** `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/render-effort-offer.sh" --plan-file <the plan file> --case done|new-work --name '<name>'`, with no `--open-effort`: `done` when its work looks done, `new-work` when the human moved on.
- **The gate's label:** `effort-state-offer`, with `--effort '<folder>'`.
- **On "now ask":** Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/state-offer-question.json` and pass its `questions` to one AskUserQuestion as written.
- **The offer can't be shown or asked:** change nothing, go on with the work, and treat it as "Keep going".

10.4 **Act on the answer:**
- **"Keep going":** nothing is written; go on with the work.
- **"Pause", "Complete" or "Drop":** Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/state-change.md` and follow it from step 9.2, with this effort's folder.
- **A typed answer:** a reply: answer it, and change nothing.
- Then, in case `new-work`: the new request goes by CLAUDE.md §4, which may offer it its own effort (SKILL.md step 1).
