---
name: jobs-assign
description: Starts a defined job's agent - a fresh one, or one that already ran a job - by the one call job-assign.sh prints, so the job, its agent and its tree are linked. Use when a defined job is ready to start.
---

# Jobs assign

A defined job starts through `job-assign.sh`: run it for the job and send exactly the call it prints. A job that cuts its tree needs the tree first; the script says how. To give a job to an agent that already ran one, name it with `--hot`; the script says when a fresh agent is needed instead.

The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract.
