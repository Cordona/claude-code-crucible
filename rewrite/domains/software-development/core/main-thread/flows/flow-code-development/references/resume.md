# Resume: the effort's seats after a break

Its terms and steps are SKILL.md's.

1. **The context:** load `procedure-context` with the Skill tool, with the effort folder, and take the `CONTEXT_FILE:` it hands back. With no version yet, nothing below runs until it hands one over. When its "what next?" is answered "Dispatch agents", or it hands a version over, come back here; never split again the parts that already have seats.
2. **What is on disk:** with no `<slots>` file, no seat was opened: go on from SKILL.md step 2. Otherwise run `jq -r '.slots[] | [.slot, .status] | @tsv' '<slots>'`, then `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/crucible.sh" find --effort '<effort folder>' --kind dispatches` (newest first), and per dispatch file `jq -r '[.slot, .task] | @tsv' '<dispatch file>'`: a seat's part is its newest dispatch's task. When a read fails, show its output and record `not checked` for each seat it leaves unknown.
3. **One state per seat,** by its status:
   - **`open` with a dispatch file of its slot:** never launched (a denial, or a break before the call): take its part through SKILL.md step 2.5 again. Only when `<effort folder>/logs/seat-bind.log` holds a `fault` line for its slot (a launch whose binding failed), ask the human first whether its agent may still run: "it may" records it `not checked`; otherwise re-plan it, its task saying the worktree may hold uncommitted work to continue from. `open` with none: SKILL.md step 2.5 for its part when the conversation or the human names its task; otherwise leave it.
   - **`working`:** its todo item records `not committed`, or no send since its last result: SKILL.md step 4's `working` line. Otherwise, after a compaction in the same session, its run may still end: wait for it (SKILL.md step 4). In a new session, or when you can't tell, ask the human whether its agent may still run: "it may" records it `not checked`; "it doesn't": SKILL.md step 4's `working` line, its run ended.
   - **`idle`:** show the line `Checked earlier, <done or blocked>: <task> · <short sha of its worktree's HEAD>`, done or blocked by SKILL.md Terms' done test; its card only when the human asks.
   - **`gave-up`:** SKILL.md step 4's `gave-up` line.
4. **Parts with no seat:** a part the conversation still shows `waiting for <task>` goes on once that part is done (SKILL.md 2.4); in a new session the human may name such parts (SKILL.md Terms' ask).
5. **Then** go on from SKILL.md step 5.
