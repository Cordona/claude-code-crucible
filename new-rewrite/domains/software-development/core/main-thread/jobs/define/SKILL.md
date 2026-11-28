---
name: jobs-define
description: Turns the jobs you and the human agree on for a step into defined jobs - you propose them, a script makes them full, the human approves them at one gate, a script writes them down. Use when a step of the flow needs work done by a build, test or review agent. Writes job.defined events through its scripts; starts no agent.
---

# Job define

The human approves jobs, not agents. For a step, propose the jobs it needs in one file: each one's kind, plugins and tree. Each kind is a file in this skill's `kinds/` folder; what a kind needs, the resolve script tells you.

**Resolve, show, define.** `job-resolve.sh` makes your jobs full from the effort; fix every fault it names and run it again. `job-card.sh` shows the human the resolved jobs at a recorded gate. Once they approve, `job-define.sh` writes the jobs down. A changed proposal is a new one: resolve and show it again.

The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract.
