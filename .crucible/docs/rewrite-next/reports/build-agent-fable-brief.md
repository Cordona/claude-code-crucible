# The build agent: two mechanics changes, brief for the Fable Reviwer

By Dev Beta. These are the owner's proposals, after reading `build-agent.md` (the builder's slice of `report-schemas.md` draft 3). They are rewrite mechanics only, so the owner sends them to you without the workers. Talking only; the owner's go is the only go.

## 1. The working commit carries the agent's configuration

```text
crucible(build): add a retry limit to the upload client

Effort: upload-retries
Job: build-php-af6bac
Language: php
Framework: laravel
Standards: security, observability, persistence
Model: <the job's model, when the dispatch names one>
```

- **Where it comes from:** the job's `job.dispatched`, which holds the plugins the agent was set up with. The stop hook stamps it; the agent never writes it.
- **Readers:**
  - the human in `git log`: which setup produced which work;
  - later, the landing step;
  - later, comparing outcomes by setup (e.g. declines per builder setup).
- **Cost:** working commits never land, so nothing leaks into company history.
- **`Model`** is my addition, as part of the configuration. Drop it if nothing reads it.

## 2. The submission event carries only where the report is, and that it hasn't changed

Draft 3's `build.submitted` copies extracts of the report: `red`, `blocked`, `security`, and on a fix `answers`. The owner asks why, since the report is validated and the event points at it.

**My original reason** was rule 0.4: "a step that decides never opens a report". **The owner's point:** the extracts are a second copy of facts the report already holds, the same argument you made against `files`.

**Proposal:**
- after validating, the stop hook makes the report read-only and records its hash in the event;
- the event carries `report`, `report_sha256`, `commit`, `job` and `agent`, the same for a build and a fix;
- the readers that decide read the report:
  - `next.sh`: red, blocked, security;
  - the next review job: the fixer's answers;
  - the merge.

  Each checks the hash first, and refuses on a mismatch.

```json
{ "type": "build.submitted",
  "body": { "job": 2, "agent": "af6bac…", "report": "reports/2.json", "report_sha256": "…", "commit": "9f3c1e2" } }
```

If you agree, this applies to every submission event in the spec (test, test plan, challenge, review, ruling). Rule 0.4 becomes: "the event says where the report is and pins it; scripts that decide read the validated report".

## Questions

1. Do the configuration trailers pass your reader test? Is `Model` worth it?
2. Is the slim event right? Is the read-only report plus its hash enough to make it the one source, or does a rule that reads only events (an event-writer rule, under the lock) need any extract?
3. Anything else in `build-agent.md` before it is built?

Please answer in `build-agent-fable.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
