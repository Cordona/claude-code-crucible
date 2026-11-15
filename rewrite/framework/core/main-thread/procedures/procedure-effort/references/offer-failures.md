# When the effort offer can't be shown or asked

Showing a line is as SKILL.md's Steps set.

- **The pipe exits non-zero:** the exit is `open-gate.sh`'s, so read the stderr. A `render-effort-offer.sh: install:` line is an install fault: show the line `offer_not_installed`, and start no effort. Any other `render-effort-offer.sh:` line is a refused input: fix what it names and run `procedure-approval-gate`'s step 1 again, once. A second refusal, or no renderer line: show the human the stderr and exit code, and start no effort.
- **The offer's question can't be read** (a failed Read of `offer-question.json` or `mixed-offer-question.json`, or a file that isn't one JSON object with a `questions` array): ask nothing, show the line `offer_question_not_read`, and start no effort.
- **`procedure-approval-gate` won't load, or says the plan was not shown:** show the line `offer_not_shown`, and start no effort.
