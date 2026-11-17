# Live validation

How you and the human check a build live, once the human picks Live-validate at SKILL.md's What next. Its terms are SKILL.md's. You run it with the human; no agent is dispatched for it.

Copy its steps into the todo list, as SKILL.md's Steps do.

1. **Run it:** do the `action` you wrote into What next's plan file (its Live-validate option names it) yourself, from the build seat's worktree (the `worktree` that `sh "<seat scripts>/seats/seats.sh" get --effort '<effort folder>' --seat '<seat>'` prints); mount the seat only on the human's yes, by `procedure-git-worktree`'s `mount.md`. A part only the human can do (a page in their browser): tell them what to do and what to look for. Change no file to make it pass: a fix is the builder's (SKILL.md Changes). Write nothing into the worktree: send each output (a log, a file a command writes) to your session's scratchpad, since the tester works in that worktree next; one that landed there anyway: tell the human, who cleans it before tests. Show the commands and their outputs only when the human asks for evidence, in a message of their own: only script-printed cards sit above a gate.
2. **Ask:** load `procedure-approval-gate` with the Skill tool, if it isn't in context, and follow its steps, with these inputs:
   - **The plan file:** `{"seat": "<build seat>", "action": "<one line naming only what you ran (the commands, a page the human opened), with no result and no claim it showed anything>"}`, written with the Write tool; no other field (the renderer takes the seat's title from its build card).
   - **The renderer:** `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/flow-code-build/scripts/render-live-check.sh" --plan-file '<the plan file>' --effort '<effort folder>'`; act on each exit as its `--help` sets.
   - **The gate's label:** `live-check`, with `--effort '<effort folder>'`.
   - **Above the gate:** the cards shown this turn, never step 1's output.
   - **On "now ask":** as SKILL.md What next sets, with this renderer.
   - **The gate can't be shown or asked:** show the human what failed, and go no further: no context doc, no tests, no `chains.md`.
   - **The answer:** matched as SKILL.md What next's answers are: `Confirmed`: step 3; `Not as asked: say what` or a typed answer: step 4.
3. **Confirmed:** load `procedure-context` with the Skill tool and follow its Add to it with the effort folder. Its doc is `live-validation.md` in the docs folder `context.sh docs` prints, one per docs folder: Read it when it is there, then Write it whole, keeping every confirmation since the last cut and adding this one, in this shape:

   ```markdown
   # Live validation

   What the human confirmed on the build of <seat> (build iteration <n>):

   - <one line per behaviour the human confirmed>
   ```

   `<n>` is one less than the `ITERATION:` line `sh "<seat scripts>/seats/iteration.sh" --effort '<effort folder>' --seat '<seat>'` prints. Each line says in your words what the human confirmed, never a pasted output. Then its hand-over telling this flow the context changed, with no "what next?"; then What next's Write tests. Only a fresh agent's dispatch, the tester's included, reads the doc, once that dispatch cuts it: a hot agent keeps the context it was sent, and a re-seated one the context its dispatch pinned.
4. **Not as asked, or a typed answer:** SKILL.md Changes with the human's words; `Not as asked: say what` picked with no words: ask in chat what is wrong first.
