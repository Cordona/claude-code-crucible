# New work on a seat

New work the human asks for on a seat that exists, after its last work was shown; a change to work already shown stays Changes, and a test ask is no new work: it goes to `flow-code-test` (SKILL.md Changes, tests). Its terms are SKILL.md's, and the task's send is `procedure-seat-run`'s New work.

Copy its steps into the todo list, as SKILL.md's Steps do.

1. **Decide with the human** (SKILL.md Always), from their ask, asking what it leaves open:
   - **Where it starts:** moved to another commit main picks (a branch it cut, the remote main, a release branch, another MR), or where the seat is now.
   - **The agent:** the hot agent goes on when its plugins fit the new work; a fresh agent when the work needs other plugins or the agent is spent. Plugins come from each plan, not the seat.
2. **The move,** when the work starts elsewhere: by `procedure-git-worktree`'s `move-and-catch-up.md` (Move), the branch or ref passed by its name. A refusal: send nothing (`procedure-seat-run`'s Always, Send nowhere).
3. **The send:** follow `procedure-seat-run`'s New work for the agent step 1 settled: the hot agent, or a fresh agent, whose plan step is SKILL.md step 2.5, as a new plan on that seat. On the seat it hands back: SKILL.md Close the run for this work alone.
