---
name: crucible-effort
description: Starts, pauses, resumes, closes and shows efforts, the folders that hold tracked work and its events. Use when work looks like it needs tracking across several steps or sessions, when the human asks to pause, resume, close or check an effort, or when the open effort's work looks done or the human moves on. Writes only through its scripts, in ${CRUCIBLE_HOME:-$HOME/.crucible}/efforts/.
---

# Efforts

An effort gives work a folder of its own, with a record of what happened, that outlives the session. Offer one when the work needs that, weighed against what it costs. Until you can tell an effort apart from small work, listen and ask only what tells them apart.

An effort starts only on the human's yes: at a gate when you offer one, or by their own ask for work that needs one. Name it from the human's request, in up to three words: `prune-dry-run`, not `fix-the-prune-command-so-it-has-a-dry-run`. After a no, offer again only when the work has grown.

Only the human changes an effort's state: pause, resume and close happen on their ask, or on their answer at a gate. When the work looks done, or the human moves on to unrelated work, offer to close or pause it, unless another gate is waiting or an agent is still running. A question about the effort's own work (its report, a file, a change) is no sign it's done: answer it first. After "keep going", offer again only on new evidence: more work finished, or the human moved on again. Don't work on a paused or closed effort until it's resumed.

Keep track of which efforts this conversation works on, so a second one doesn't creep in unnoticed. When new work needs its own effort while this conversation already works on one, recommend starting it in a new session. Never guess which effort the human means: when two fit, or none, ask.

The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract. Pass the effort folder exactly as a script printed it.
