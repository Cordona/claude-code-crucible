# Offering a grill

How to offer a grill and act on the answer. Read it at SKILL.md step 1, only when you raise the grill (never on the human's ask) and SKILL.md's Never section allows an offer. Step numbers are SKILL.md's, and so is `<views>`.

Load `procedure-approval-gate` with the Skill tool and follow its steps, with these inputs:

- **The plan file:** the reasons the goal looks open, from your judgment, in the shape `render-effort-offer.sh --help` sets.
- **The renderer:** `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/render-effort-offer.sh" --plan-file '<the plan file>' --title 'grill this first?'`.
- **The gate's label:** `grill-offer`, with `--effort '<effort folder>'` only inside an effort.
- **The pipe exits non-zero:** a `render-effort-offer.sh: install:` line: show the line `offer_not_installed`, and go on as on "No, go on". Any other `render-effort-offer.sh:` line: fix what it names and run `procedure-approval-gate`'s step 1 again, once. A second refusal, or no renderer line: show the human the stderr and exit code, and go on as on "No, go on".
- **On "now ask":** Read the question file SKILL.md step 1 names, `offer-question.json`, with the folder expanded to an absolute path, and pass its `questions` to one AskUserQuestion as written. A failed Read, or not one JSON object with a `questions` array: ask nothing, show the line `offer_question_not_read`, and go on as on "No, go on".
- **The Skill tool can't load `procedure-approval-gate`, or it reports the plan not shown:** show the line `offer_not_shown`, and go on as on "No, go on".

Act on the answer:

- **"Yes, grill me":** step 2.
- **"No, go on":** no grill; the work goes on with what is known. Offered from `procedure-context`'s discovery (its step 1): go back to that discovery talk, never to CLAUDE.md §4 or the flow's start. Otherwise, go on as CLAUDE.md §4's next lines route it.
- **A typed answer:** a reply, not a revision: answer it as the turn's last message, and start no grill. At the human's next message, offer again from step 1, unless their reply chose a path; then take that path, as the two answers above set.
