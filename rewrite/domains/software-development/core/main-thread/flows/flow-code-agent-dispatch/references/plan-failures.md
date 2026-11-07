# Plan failures

Step 7's results other than the ones its sub-steps go on from. Step numbers are SKILL.md's.

## 7.1 Write it

- That `open-gate.sh` failure: show the human its output and exit code, and hand this part back as `stopped: plan not shown`.
- Generator exit 0 without any of its three lines (`PLAN_FILE:`, `PLAN_SHA256:`, `PLAN_RECORD:`): as any other exit.
- Generator exit 2 or 3: fix the options stderr names and run it again, at most twice as SKILL.md's Never sets (a problem led by the token `CONTEXT-STALE`: the context handed in is no longer the effort's latest version; rerun with the latest as `--context-file`); then show the human the stderr, and hand this part back as `stopped: plan not shown`.
- Any other generator exit: show the human the stdout, stderr and exit code, and hand this part back as `stopped: plan not shown`.

## 7.2 Show it

- A stderr line starting `render-dispatch-plan.sh: install:` is an install or host fault: show it to the human at once.
- The plan not shown, for this or any reason the gate gives: hand this part back as `stopped: plan not shown`, unasked (SKILL.md's Never).

## 7.3 Ask it

- A non-zero exit, or stdout other than none that isn't one JSON object with its `header`, `question` and `options`: show the human the stdout, stderr and exit code, and, unasked (SKILL.md's Never), hand this part back as `stopped: question not rendered`.
