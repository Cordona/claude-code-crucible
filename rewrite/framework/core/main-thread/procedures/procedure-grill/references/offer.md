# Offering a grill

How to offer a grill and act on the answer; read at SKILL.md step 1, only when you raise the grill (never on the human's ask) and SKILL.md Never allows an offer. Step numbers are SKILL.md's.

Load `procedure-approval-gate` with the Skill tool and follow its steps, with these inputs:

- **The plan file:** the reasons the goal looks open, from your judgment, in the shape `render-effort-offer.sh --help` sets.
- **The renderer:** `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/render-effort-offer.sh" --plan-file <the plan file> --title 'grill this first?'`; its `--help` runs once per session, before the first call.
- **The gate's label:** `grill-offer`, with `--effort '<effort folder>'` only inside an effort.
- **The pipe exits non-zero:** a `render-effort-offer.sh: install:` line: show the line `The grill offer could not be shown: its renderer is not installed correctly.`, and go on as on "No, go on". Any other `render-effort-offer.sh:` line: fix what it names and run `procedure-approval-gate`'s step 1 again, once. A second refusal, or no renderer line: show the human the stderr and exit code, and go on as on "No, go on".
- **On "now ask":** Read the question file SKILL.md step 1 names, `offer-question.json`, with the folder expanded to an absolute path, and pass its `questions` to one AskUserQuestion as written. A failed Read, or not one JSON object with a `questions` array: ask nothing, show the line `The grill offer's question could not be read.`, and go on as on "No, go on".
- **The Skill tool can't load `procedure-approval-gate`, or it reports the plan not shown:** show the line `The grill offer could not be shown.`, and go on as on "No, go on".

Act on the answer:

- **"Yes, grill me":** step 2.
- **"No, go on":** no grill; the work goes on with what is known, as CLAUDE.md §4's next lines route it.
- **A typed answer:** a reply, not a revision: answer it as the turn's last message, and start no grill. At the human's next message, offer again from step 1, unless their reply chose a path: then take it.
