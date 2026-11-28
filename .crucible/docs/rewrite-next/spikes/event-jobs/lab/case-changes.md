# Case command changes

Only the reading part of each command changed: `jq -s -c FILTER "$EFFORT"/events/*.json` became `lab/view.sh --effort "$EFFORT" | jq -c FILTER`, with the same filter. No expect.json changed.

| Case | Reason |
|---|---|
| a11-01-orphan-died-once | real envelope |
| a11-03-dispatched-never-assigned | real envelope |
| a11-02-same-session-not-orphan | real envelope |
| a2-14-deadlocked-key-only-to-arbiter | real envelope |
| a4-02-ids-unique-across-rounds | real envelope |
| a4-03-fix-across-two-rounds-answered | real envelope |
| a3-04-replacement-counted-once | real envelope |
| a5-04-choose-resolves-query | real envelope |
| a5-03-fix-job-holds-only-chosen | real envelope |
| a5-01-cover-includes-chosen-files | real envelope |
| a5-02-skipped-listed-to-rereviewer | real envelope |
| a5-06-cover-real-fix | real envelope |
| a7-12-external-round-cover | real envelope |
