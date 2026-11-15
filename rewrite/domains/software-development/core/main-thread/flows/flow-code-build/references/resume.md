# Resume: the effort's seats after a break

Its terms and steps are SKILL.md's. Copy its steps into the todo list and tick each.

1. **The context:** load `procedure-context` with the Skill tool, with the effort folder, and take the `CONTEXT_DOCS:` or `CONTEXT_FILE:` line it hands back; nothing below runs until it hands one over. Once it does, come back here; never split again a part that has a seat in the seat list, chosen or later (SKILL.md 2.4); a dropped seat no longer counts.
2. **The seats:** load `procedure-seat-run` with the Skill tool, if it isn't in context, and follow its Resume, which reads the seat list and takes each `open`, `working`, `idle` and `gave-up` seat back up. What it hands back: no seat held: go on from SKILL.md step 2; an `open` seat with its part: take that part through SKILL.md step 2.5 with that seat; each `chosen` seat: step 3.
3. **`chosen`:** a plan never answered. When this session still holds its part (its todo item `<seat>: <task>` or the conversation, as after a compaction), take that part through SKILL.md step 2.5 with that seat; when it can't tell: show `procedure-seat-run`'s line `part_not_done` (`--views <seat views>`), with `--arg task '<seat>'` and `--arg why 'plan never answered'`, then offer to drop it: load `procedure-approval-gate` with the Skill tool and follow its steps, one such seat at a time, with these inputs:
   - **The plan file:** `{"seat": "<seat>"}`, written with the Write tool.
   - **The renderer:** `<show.sh> render --views <views> --name drop-seat < '<the plan file>'`.
   - **The gate's label:** `seat-drop`, with `--effort '<effort folder>'`.
   - **Above the gate:** `procedure-seat-run`'s line `part_not_done` (`--views <seat views>`), with the other cards shown this turn.
   - **On "now ask":** Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/flow-code-build/references/drop-question.json` and pass its `questions` to one AskUserQuestion as written.
   - **The answer:** `Drop it (Recommended)` → `sh "<seat scripts>/seats/seats.sh" drop --effort '<effort folder>' --seat '<seat>'`; a refusal: show its stderr and leave the seat. `Keep it`: leave the seat. A typed answer: open the gate again.
   - **The gate can't be shown or asked:** show the human what failed, and leave the seat.
4. **Parts with no seat:** a part the conversation still shows `waiting for <task>` goes on once that part is done (SKILL.md 2.4); in a new session the human may name such parts (SKILL.md Terms, a part's record).
5. **Then** go on from SKILL.md Close the run.
