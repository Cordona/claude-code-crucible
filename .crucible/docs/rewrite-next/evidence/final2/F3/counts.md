# Step 4: counts per kind

Written by `score.sh` from `logs/`. A run is one cell, `<kind>-<n>`. Parked cells are in `parked.md`.

| Kind | Runs | Accepted at the first stop | Repaired after one refusal | Gave up | Other |
|---|---|---|---|---|---|
| build | 3 | 3 | 0 | 0 | 0 |
| external-review | 3 | 3 | 0 | 0 | 0 |
| test | 3 | 3 | 0 | 0 | 0 |
| test-plan | 3 | 2 | 1 | 0 | 0 |
| test-plan-update | 3 | 2 | 1 | 0 | 0 |

## Flagged: a line that refused the same kind in 2 runs of 3 or more

None.

## Text lengths per field (live reports of the counted runs)

| Kind | Field | n | min | median | p90 | max | over 200 |
|---|---|---|---|---|---|---|---|
| build | `decisions[].at` | 10 | 23 | 23 | 23 | 23 | 0 |
| build | `decisions[].choice` | 10 | 64 | 98 | 143 | 174 | 0 |
| build | `decisions[].why` | 10 | 74 | 110 | 151 | 162 | 0 |
| build | `gates[].gate` | 12 | 4 | 4 | 9 | 9 | 0 |
| build | `gates[].note` | 12 | 26 | 39 | 125 | 159 | 0 |
| build | `gates[].result` | 12 | 4 | 4 | 7 | 7 | 0 |
| build | `noticed[].at` | 2 | 11 | 11 | 23 | 23 | 0 |
| build | `noticed[].text` | 2 | 60 | 60 | 72 | 72 | 0 |
| build | `questions[].text` | 3 | 135 | 147 | 195 | 195 | 0 |
| build | `summary` | 3 | 155 | 159 | 163 | 163 | 0 |
| external-review | `items[].finding.at` | 3 | 23 | 26 | 26 | 26 | 0 |
| external-review | `items[].finding.claim` | 3 | 141 | 142 | 148 | 148 | 0 |
| external-review | `items[].finding.id` | 3 | 8 | 8 | 8 | 8 | 0 |
| external-review | `items[].finding.realism` | 3 | 9 | 9 | 9 | 9 | 0 |
| external-review | `items[].finding.severity` | 3 | 8 | 8 | 8 | 8 | 0 |
| external-review | `items[].finding.suggestion` | 3 | 144 | 165 | 191 | 191 | 0 |
| external-review | `items[].item` | 6 | 9 | 12 | 19 | 19 | 0 |
| external-review | `items[].reply` | 6 | 268 | 371 | 445 | 445 | 6 |
| external-review | `items[].source` | 15 | 3 | 5 | 5 | 5 | 0 |
| external-review | `items[].thread` | 15 | 2 | 2 | 11 | 11 | 0 |
| external-review | `items[].verdict` | 15 | 5 | 5 | 8 | 8 | 0 |
| external-review | `noticed[].at` | 4 | 23 | 23 | 23 | 23 | 0 |
| external-review | `noticed[].kind` | 3 | 11 | 11 | 11 | 11 | 0 |
| external-review | `noticed[].text` | 7 | 167 | 183 | 269 | 269 | 3 |
| test | `decisions[].at` | 2 | 22 | 22 | 22 | 22 | 0 |
| test | `decisions[].choice` | 2 | 87 | 87 | 92 | 92 | 0 |
| test | `decisions[].why` | 2 | 151 | 151 | 160 | 160 | 0 |
| test | `gates[].gate` | 9 | 4 | 4 | 8 | 8 | 0 |
| test | `gates[].note` | 9 | 15 | 90 | 272 | 272 | 2 |
| test | `gates[].result` | 9 | 4 | 4 | 4 | 4 | 0 |
| test | `gates[].where` | 1 | 16 | 16 | 16 | 16 | 0 |
| test | `summary` | 3 | 109 | 115 | 138 | 138 | 0 |
| test-plan | `baseline.gate` | 3 | 4 | 4 | 4 | 4 | 0 |
| test-plan | `baseline.note` | 3 | 22 | 39 | 39 | 39 | 0 |
| test-plan | `baseline.result` | 3 | 4 | 4 | 4 | 4 | 0 |
| test-plan | `baseline.where` | 3 | 9 | 23 | 32 | 32 | 0 |
| test-plan | `behaviours[].at` | 9 | 23 | 23 | 23 | 23 | 0 |
| test-plan | `behaviours[].at[]` | 28 | 23 | 23 | 23 | 23 | 0 |
| test-plan | `behaviours[].guarded_by[]` | 12 | 42 | 53 | 62 | 62 | 0 |
| test-plan | `behaviours[].id` | 21 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `behaviours[].text` | 21 | 75 | 113 | 134 | 154 | 0 |
| test-plan | `noticed[].at` | 9 | 11 | 23 | 23 | 23 | 0 |
| test-plan | `noticed[].text` | 9 | 84 | 118 | 143 | 143 | 0 |
| test-plan | `run[].command` | 6 | 40 | 40 | 71 | 71 | 0 |
| test-plan | `run[].where` | 6 | 9 | 13 | 24 | 24 | 0 |
| test-plan | `support[].file` | 3 | 12 | 12 | 12 | 12 | 0 |
| test-plan | `support[].what` | 3 | 86 | 92 | 186 | 186 | 0 |
| test-plan | `tests[].action` | 16 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `tests[].breaks_on` | 16 | 101 | 122 | 217 | 246 | 2 |
| test-plan | `tests[].file` | 16 | 19 | 19 | 19 | 19 | 0 |
| test-plan | `tests[].guards[]` | 17 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `tests[].id` | 16 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `tests[].level` | 16 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `tests[].name` | 16 | 36 | 43 | 59 | 63 | 0 |
| test-plan | `untested[].case` | 7 | 38 | 51 | 111 | 111 | 0 |
| test-plan | `untested[].id` | 7 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `untested[].proof` | 7 | 22 | 23 | 42 | 42 | 0 |
| test-plan | `untested[].reason` | 7 | 82 | 95 | 107 | 107 | 0 |
| test-plan | `untested[].recommend` | 7 | 4 | 4 | 4 | 4 | 0 |
| test-plan | `untested[].risk` | 7 | 45 | 60 | 74 | 74 | 0 |
| test-plan-update | `answers[].answer` | 9 | 6 | 7 | 7 | 7 | 0 |
| test-plan-update | `answers[].id` | 9 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `answers[].reason` | 3 | 170 | 192 | 202 | 202 | 1 |
| test-plan-update | `baseline.gate` | 3 | 4 | 4 | 4 | 4 | 0 |
| test-plan-update | `baseline.note` | 3 | 39 | 39 | 39 | 39 | 0 |
| test-plan-update | `baseline.result` | 3 | 4 | 4 | 4 | 4 | 0 |
| test-plan-update | `baseline.where` | 3 | 16 | 16 | 16 | 16 | 0 |
| test-plan-update | `behaviours[].at` | 5 | 23 | 23 | 23 | 23 | 0 |
| test-plan-update | `behaviours[].at[]` | 17 | 23 | 23 | 26 | 26 | 0 |
| test-plan-update | `behaviours[].guarded_by[]` | 11 | 42 | 53 | 62 | 62 | 0 |
| test-plan-update | `behaviours[].id` | 14 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `behaviours[].text` | 14 | 62 | 112 | 133 | 134 | 0 |
| test-plan-update | `noticed[].at` | 4 | 11 | 23 | 23 | 23 | 0 |
| test-plan-update | `noticed[].text` | 4 | 100 | 166 | 209 | 209 | 1 |
| test-plan-update | `run[].command` | 3 | 42 | 69 | 74 | 74 | 0 |
| test-plan-update | `run[].where` | 3 | 16 | 16 | 16 | 16 | 0 |
| test-plan-update | `support[].file` | 3 | 12 | 12 | 12 | 12 | 0 |
| test-plan-update | `support[].what` | 3 | 69 | 73 | 80 | 80 | 0 |
| test-plan-update | `tests[].action` | 12 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `tests[].breaks_on` | 12 | 116 | 150 | 218 | 251 | 2 |
| test-plan-update | `tests[].file` | 12 | 19 | 19 | 19 | 19 | 0 |
| test-plan-update | `tests[].guards[]` | 13 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `tests[].id` | 12 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `tests[].level` | 12 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `tests[].name` | 12 | 42 | 60 | 79 | 90 | 0 |
| test-plan-update | `untested[].case` | 6 | 57 | 70 | 88 | 88 | 0 |
| test-plan-update | `untested[].id` | 6 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `untested[].proof` | 6 | 8 | 8 | 23 | 23 | 0 |
| test-plan-update | `untested[].reason` | 6 | 47 | 122 | 197 | 197 | 0 |
| test-plan-update | `untested[].recommend` | 6 | 4 | 4 | 4 | 4 | 0 |
| test-plan-update | `untested[].risk` | 6 | 45 | 92 | 184 | 184 | 0 |

## Every refusal line, per kind

### build

No refusal.

### external-review

No refusal.

### test

No refusal.

### test-plan

- test-plan-1, try 1: `support[0].what names T-5: say it in words; the IDs are for scripts`

### test-plan-update

- test-plan-update-2, try 1: `untested[0].proof must be a test, a path:line, or unproven`
