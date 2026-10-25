# When the effort offer can't be shown or asked

What to do when SKILL.md step 1's offer fails; read at step 1 when the pipe exits non-zero, the offer's question can't be read, or the Skill tool can't load `procedure-approval-gate` or it reports the plan not shown. Step numbers are SKILL.md's.

- **The pipe exits non-zero** (the exit is `open-gate.sh`'s, so read the stderr): a `render-effort-offer.sh: install:` line is an install fault: show the line `The effort offer could not be shown: its renderer is not installed correctly. No effort was started.`, and start no effort. Any other `render-effort-offer.sh:` line is a refused input: fix what it names and run `procedure-approval-gate`'s step 1 again, once. A second refusal, or no renderer line: show the human the stderr and exit code, and start no effort.
- **The offer's question can't be read** (a failed Read of `offer-question.json`, or a file that isn't one JSON object with a `questions` array): ask nothing, show the line `The effort offer's question could not be read. No effort was started.`, and start no effort.
- **The Skill tool can't load `procedure-approval-gate`, or it reports the plan not shown:** show the line `The effort offer could not be shown. No effort was started.`, and start no effort.
