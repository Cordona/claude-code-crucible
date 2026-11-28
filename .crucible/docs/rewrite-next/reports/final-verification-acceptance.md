# Final verification: what must be proven, and by what (v2)

By Dev Beta, from the owner's five requirements (2026-11-25). v2 applies Fable's verdict (`final-verification-fable.md`).

Nothing counts as proven unless a script shows it from events, report files, git or saved hook output, in a run with real Claude Code sub-agents.

The runs, after the hook rework:
- **the step 3 matrix:** steered stand-ins, re-run in the real layout (main in the repo, mode default), with its control run;
- **step 4:** the real definitions on Opus, unsteered, headless;
- **step 4i:** a small interactive set in tmux, the owner's mode.

## R1 to R4

| # | Requirement | Proven by | Pass bar |
|---|---|---|---|
| R1 | **Agents produce the JSON they should, holding real work** | **step 4:** 3 runs per kind × 11 kinds, plus a parked build and a parked test. Beyond acceptance, each report is checked against facts planted in its fixture:<br>• a review of the bugged build has a finding in the file holding the bug;<br>• a fix commit touches the code its findings point at;<br>• a test commit adds tests that run;<br>• a builder and tester report their allowed checks as run. | every job submitted; zero gave up; every planted fact met. The number accepted at the first stop is reported |
| R2 | **Reports are validated, coverage included** | **step 3 S2 per kind:** a fixer leaving a finding out, a re-reviewer leaving a fix without a status, an outside-review judge skipping a thread, a rework leaving a challenge unanswered, an ID in human text. Also S3, S6, S7 and S8. Every distinct repair line has a scripted case | each refused with its line, then accepted |
| R3 | **The agent is told the exact error, automatically, and corrects itself** | **Delivery:** step 3, every kind. The control run, with all hooks removed, goes red on every scenario. **Self-repair from the lines alone:** step 4 only, since step 3's repairs were scripted. **No main involvement:** scored, as no message from main to the agent between a `job.refused` and its submission | `job.refused` with the lines, then the submission, with nothing from main between |
| R4 | **An audit trail of every failure, a give-up included** | **step 3:**<br>• S4: two refusals, then `job.ended gave-up`;<br>• S5a: `job.ended fault`;<br>• S5b: `job.stalled`, then finished or given up;<br>• S12: `job.ended no-stop`;<br>• S11: a parked stop.<br>The audit runs over every run | each job ends in exactly one ending or a submission; every refusal is an event; no job has more than 2 refusals |

## R5: what else "rock solid" needs

| # | Essential | Proven by |
|---|---|---|
| R5.1 | **No silent pass:**<br>• a job agent's stop is checked, or the human is told: no job found (A0), a hook error (the exit trap), a refusal that can't be recorded (held once, then told);<br>• the waits stay under the hook's 300 s.<br>A hook killed outright is caught at the end of main's turn (`no-stop`), not never | step 3 S10; P6; the scripted cases |
| R5.2 | **No vanished job:** an agent killed, interrupted, at its turn limit or on an API error is ended `no-stop` at main's turn end, for this session's jobs only | step 3 S12; probes P2, P7 and P10 |
| R5.3 | **No lost work:** a fault after acceptance stalls the job and keeps the pinned report; one script finishes it or gives it up | step 3 S5b; the scripted cases per step |
| R5.4 | **Tamper evidence:** a pinned report is read-only and hashed; a changed one is refused by the events view | the scripted runners; S11's late write refused |
| R5.5 | **Agents stay in their lane:** **Write and Edit** go only to the tree and the report. A shell command can still write wherever Claude Code's permissions let it, so that's limited by the allow-list, not by us. No background shells, and long commands time-limited | step 3 S13, plus a new cell: the real hook refuses a Write into the repo, the agent writes in its tree, and the repo stays clean; the cd-before-git cell; P9, P13, P17 |
| R5.6 | **Parallel safety:** twelve agents refused at once each get their own lines; IDs unique | step 3 S9; P4 |
| R5.7 | **Hot agents:** a resumed agent's new job is checked by its own rules | step 3 S1, S4 review-hot; P3, P12 |
| R5.8 | **Every event is valid:** each type's rule refuses a malformed or out-of-order event | the agent-jobs runner |
| R5.9 | **Knowing it's all there:**<br>• install-check confirms the hooks, settings and env;<br>• the probe kit rechecks Claude Code's behaviour, and the check compares the running Claude Code version with the one the probes last ran on.<br>**The owner picks when they run: by hand, or at session start** | install-check; the probe kit |

## Proven by script only, never live

- an unrecorded refusal;
- the exit trap;
- stalls at the stamp, pin, event and lock steps (the commit stall ran live);
- the no-stop writer's pinned-to-stalled;
- an idle hot agent stopping silently;
- ending a job by hand (end-job.sh);
- a second session leaving another's jobs alone.

None of these depends on Claude Code beyond what the live cells show.

## Limits, said plainly

- **The event log itself can't be written:** the human's message is then the only record.
- **jq missing, or the hooks not installed:** nothing is checked. install-check is the guard (R5.9).
- **The numbers are evidence, not a guarantee.** 33 of 33 with zero gave up is strong evidence: roughly "fewer than one in ten at worst". It says nothing about the next Claude Code version, which is why the probe kit reruns.

## Out of scope here

- **Main acting on the events** (the dispatch, the review loop, the cards): the dispatch talk. That includes the dispatch's two refusals: a new job on a tree with an open job, and a tree that isn't clean.
- **The plugins' content quality:** an integration run.
- **Whether a review is sound, or a fix correct:** judged by reviewers and the human.
