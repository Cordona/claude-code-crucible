# Waivers: flow-harness-authoring

- DET-08: no hook blocks commit, push or deploy while the flow runs; skill hooks stay registered for the rest of the session and would block the owner's own later commits; the prose rule and the G4 gate stand (owner, 2026-10-13: "Waive") (owner)
- SUB-01: the orchestrator drafts spec.md with the owner; drafting is a conversation with the owner and a subagent has no channel to the owner; the orchestrator only records the owner's answers (owner, 2026-10-13: "Waive") (owner)
- DET-05: the deploy is one symlink behind the owner's G4 gate, checked by `ls -ld`/`readlink` before and after; no plan-file validator script (owner, 2026-10-13: "Waive both") (owner)
- DET-06: run files live in the repo by design so they can be committed and shared; no outside-the-repo run-root check (owner, 2026-10-13: "Waive both") (owner)
