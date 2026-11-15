# New work on a seat

New work on a seat, once the caller has settled with the human where it starts and which agent takes it, and moved the seat when it starts elsewhere. Its terms are SKILL.md's; Changes' steps are the ones SKILL.md's New work sends you to read with this file.

Follow the step for the agent the caller names, and tick it in the todo list.

1. **The hot agent:** run `sh "<seat scripts>/seats/seats.sh" task --effort '<effort folder>' --seat '<seat>' --task '<task>'`, `<task>` the task in the human's words as one value, single-quoted, each `'` as `'\''` (CLAUDE.md's "Quote values for scripts"). Exit 0: go on; a non-zero exit: send nothing (SKILL.md Always, Send nowhere). Then Changes' Send, its new-work form; its result: SKILL.md Results, then hand the seat back to the caller for this work alone.
2. **A fresh agent:** run `sh "<seat scripts>/seats/seats.sh" handover --effort '<effort folder>' --seat '<seat>'`; a non-zero exit: send nothing (SKILL.md Always, Send nowhere). Then hand the work back to the caller's plan step as a new plan on that seat, shown at the dispatch-plan gate with its plugins; its dispatch comes back to SKILL.md Launch, then Results.
