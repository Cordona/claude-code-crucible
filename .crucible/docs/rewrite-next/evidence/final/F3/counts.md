# Step 4: counts per kind

Written by `score.sh` from `logs/`. A run is one cell, `<kind>-<n>`. Parked cells are in `parked.md`.

| Kind | Runs | Accepted at the first stop | Repaired after one refusal | Gave up | Other |
|---|---|---|---|---|---|
| build | 3 | 0 | 3 | 0 | 0 |
| build-fix | 3 | 3 | 0 | 0 | 0 |
| external-review | 3 | 0 | 3 | 0 | 0 |
| foreign-review | 3 | 2 | 1 | 0 | 0 |
| re-review | 3 | 3 | 0 | 0 | 0 |
| review | 3 | 3 | 0 | 0 | 0 |
| test | 3 | 0 | 3 | 0 | 0 |
| test-fix | 3 | 1 | 2 | 0 | 0 |
| test-plan | 3 | 1 | 2 | 0 | 0 |
| test-plan-challenge | 3 | 3 | 0 | 0 | 0 |
| test-plan-update | 3 | 1 | 2 | 0 | 0 |

## Flagged: a line that refused the same kind in 2 runs of 3 or more

- **build** (2 runs): `decisions[N].at bin/prune-backups.sh pipeline names no file in the tree`
- **build** (2 runs): `decisions[N].at bin/prune-backups.sh verbose output names no file in the tree`
- **external-review** (3 runs): `noticed[N].at description names no file in the tree`
- **test-fix** (2 runs): `you changed tests/lib.sh, which isn't in the approved plan: undo it, or add a decisions entry at it saying why`
- **test-plan** (2 runs): `behaviours[N].at "bin/prune-backups.sh:N-N,N" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- **test-plan** (2 runs): `behaviours[N].at "bin/prune-backups.sh:N,N" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- **test** (2 runs): `decisions[N].at "tests/test_prune.sh: dry run lists the extra backups and deletes none" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- **test** (3 runs): `decisions[N].at "tests/test_prune.sh: --pattern without a value is a usage error" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`

## Text lengths per field (live reports of the counted runs)

| Kind | Field | n | min | median | p90 | max | over 200 |
|---|---|---|---|---|---|---|---|
| build | `decisions[].at` | 11 | 9 | 23 | 23 | 23 | 0 |
| build | `decisions[].choice` | 11 | 68 | 85 | 111 | 112 | 0 |
| build | `decisions[].why` | 11 | 73 | 86 | 122 | 141 | 0 |
| build | `gates[].gate` | 15 | 4 | 6 | 9 | 9 | 0 |
| build | `gates[].note` | 15 | 24 | 52 | 147 | 149 | 0 |
| build | `gates[].result` | 15 | 4 | 4 | 7 | 7 | 0 |
| build | `questions[].text` | 4 | 108 | 130 | 149 | 149 | 0 |
| build | `summary` | 3 | 131 | 144 | 163 | 163 | 0 |
| build-fix | `decisions[].at` | 8 | 15 | 23 | 26 | 26 | 0 |
| build-fix | `decisions[].choice` | 8 | 35 | 90 | 136 | 136 | 0 |
| build-fix | `decisions[].why` | 8 | 68 | 106 | 148 | 148 | 0 |
| build-fix | `fixes[].id` | 9 | 8 | 8 | 8 | 8 | 0 |
| build-fix | `fixes[].note` | 9 | 49 | 70 | 138 | 138 | 0 |
| build-fix | `fixes[].status` | 9 | 4 | 4 | 4 | 4 | 0 |
| build-fix | `gates[].gate` | 12 | 4 | 4 | 9 | 9 | 0 |
| build-fix | `gates[].note` | 12 | 15 | 50 | 146 | 156 | 0 |
| build-fix | `gates[].result` | 12 | 4 | 4 | 7 | 7 | 0 |
| build-fix | `questions[].text` | 2 | 119 | 119 | 154 | 154 | 0 |
| build-fix | `summary` | 3 | 141 | 155 | 161 | 161 | 0 |
| external-review | `items[].finding.at` | 3 | 26 | 26 | 26 | 26 | 0 |
| external-review | `items[].finding.claim` | 3 | 137 | 156 | 172 | 172 | 0 |
| external-review | `items[].finding.id` | 3 | 8 | 8 | 8 | 8 | 0 |
| external-review | `items[].finding.realism` | 3 | 9 | 9 | 9 | 9 | 0 |
| external-review | `items[].finding.severity` | 3 | 8 | 8 | 8 | 8 | 0 |
| external-review | `items[].finding.suggestion` | 3 | 163 | 172 | 175 | 175 | 0 |
| external-review | `items[].item` | 6 | 9 | 12 | 19 | 19 | 0 |
| external-review | `items[].note` | 1 | 188 | 188 | 188 | 188 | 0 |
| external-review | `items[].reply` | 6 | 342 | 370 | 446 | 446 | 6 |
| external-review | `items[].source` | 15 | 3 | 5 | 5 | 5 | 0 |
| external-review | `items[].thread` | 15 | 2 | 2 | 11 | 11 | 0 |
| external-review | `items[].verdict` | 15 | 5 | 5 | 8 | 8 | 0 |
| external-review | `noticed[].at` | 7 | 20 | 23 | 23 | 23 | 0 |
| external-review | `noticed[].kind` | 3 | 11 | 11 | 11 | 11 | 0 |
| external-review | `noticed[].text` | 7 | 216 | 223 | 247 | 247 | 7 |
| foreign-review | `findings[].at` | 16 | 24 | 24 | 24 | 24 | 0 |
| foreign-review | `findings[].claim` | 16 | 118 | 178 | 237 | 239 | 4 |
| foreign-review | `findings[].id` | 16 | 8 | 8 | 8 | 8 | 0 |
| foreign-review | `findings[].proof` | 4 | 162 | 191 | 227 | 227 | 1 |
| foreign-review | `findings[].realism` | 16 | 9 | 9 | 9 | 9 | 0 |
| foreign-review | `findings[].relates_to` | 1 | 24 | 24 | 24 | 24 | 0 |
| foreign-review | `findings[].severity` | 16 | 3 | 4 | 6 | 6 | 0 |
| foreign-review | `findings[].suggestion` | 16 | 70 | 144 | 194 | 195 | 0 |
| foreign-review | `notes[].at` | 7 | 23 | 23 | 23 | 23 | 0 |
| foreign-review | `notes[].text` | 7 | 117 | 142 | 187 | 187 | 0 |
| foreign-review | `noticed[].at` | 4 | 9 | 11 | 21 | 21 | 0 |
| foreign-review | `noticed[].for` | 1 | 5 | 5 | 5 | 5 | 0 |
| foreign-review | `noticed[].text` | 4 | 82 | 124 | 138 | 138 | 0 |
| re-review | `fixes[].id` | 9 | 8 | 8 | 8 | 8 | 0 |
| re-review | `fixes[].reason` | 6 | 172 | 196 | 242 | 242 | 2 |
| re-review | `fixes[].status` | 9 | 4 | 5 | 8 | 8 | 0 |
| re-review | `notes[].at` | 6 | 23 | 23 | 23 | 23 | 0 |
| re-review | `notes[].text` | 6 | 100 | 143 | 170 | 170 | 0 |
| review | `findings[].at` | 9 | 23 | 26 | 26 | 26 | 0 |
| review | `findings[].claim` | 9 | 145 | 162 | 203 | 203 | 1 |
| review | `findings[].id` | 9 | 8 | 8 | 8 | 8 | 0 |
| review | `findings[].proof` | 6 | 107 | 150 | 232 | 232 | 1 |
| review | `findings[].realism` | 9 | 9 | 9 | 9 | 9 | 0 |
| review | `findings[].relates_to` | 3 | 23 | 23 | 23 | 23 | 0 |
| review | `findings[].severity` | 9 | 3 | 6 | 8 | 8 | 0 |
| review | `findings[].suggestion` | 9 | 73 | 129 | 254 | 254 | 2 |
| review | `notes[].at` | 7 | 23 | 26 | 26 | 26 | 0 |
| review | `notes[].text` | 8 | 89 | 126 | 188 | 188 | 0 |
| review | `noticed[].at` | 2 | 11 | 11 | 23 | 23 | 0 |
| review | `noticed[].for` | 1 | 4 | 4 | 4 | 4 | 0 |
| review | `noticed[].text` | 2 | 117 | 117 | 121 | 121 | 0 |
| test | `decisions[].at` | 5 | 25 | 25 | 25 | 25 | 0 |
| test | `decisions[].choice` | 5 | 63 | 75 | 92 | 92 | 0 |
| test | `decisions[].why` | 5 | 94 | 125 | 144 | 144 | 0 |
| test | `gates[].gate` | 9 | 4 | 4 | 8 | 8 | 0 |
| test | `gates[].note` | 9 | 39 | 88 | 201 | 201 | 1 |
| test | `gates[].result` | 9 | 4 | 4 | 4 | 4 | 0 |
| test | `gates[].where` | 1 | 16 | 16 | 16 | 16 | 0 |
| test | `summary` | 3 | 112 | 115 | 117 | 117 | 0 |
| test-fix | `decisions[].at` | 9 | 18 | 22 | 25 | 25 | 0 |
| test-fix | `decisions[].choice` | 9 | 52 | 143 | 188 | 188 | 0 |
| test-fix | `decisions[].why` | 9 | 91 | 130 | 151 | 151 | 0 |
| test-fix | `fixes[].id` | 9 | 10 | 10 | 10 | 10 | 0 |
| test-fix | `fixes[].note` | 9 | 76 | 116 | 135 | 135 | 0 |
| test-fix | `fixes[].status` | 9 | 4 | 4 | 4 | 4 | 0 |
| test-fix | `gates[].gate` | 10 | 4 | 4 | 8 | 8 | 0 |
| test-fix | `gates[].note` | 10 | 15 | 73 | 172 | 187 | 0 |
| test-fix | `gates[].result` | 10 | 4 | 4 | 4 | 7 | 0 |
| test-fix | `gates[].where` | 1 | 15 | 15 | 15 | 15 | 0 |
| test-fix | `noticed[].at` | 1 | 22 | 22 | 22 | 22 | 0 |
| test-fix | `noticed[].text` | 1 | 205 | 205 | 205 | 205 | 1 |
| test-fix | `summary` | 3 | 133 | 148 | 159 | 159 | 0 |
| test-plan | `baseline.gate` | 3 | 4 | 4 | 4 | 4 | 0 |
| test-plan | `baseline.note` | 3 | 38 | 39 | 157 | 157 | 0 |
| test-plan | `baseline.result` | 3 | 4 | 4 | 4 | 4 | 0 |
| test-plan | `baseline.where` | 3 | 9 | 16 | 34 | 34 | 0 |
| test-plan | `behaviours[].at` | 19 | 23 | 23 | 26 | 26 | 0 |
| test-plan | `behaviours[].guarded_by[]` | 10 | 42 | 53 | 54 | 62 | 0 |
| test-plan | `behaviours[].id` | 19 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `behaviours[].text` | 19 | 65 | 117 | 133 | 157 | 0 |
| test-plan | `noticed[].at` | 6 | 11 | 11 | 23 | 23 | 0 |
| test-plan | `noticed[].text` | 6 | 98 | 101 | 151 | 151 | 0 |
| test-plan | `run[].command` | 5 | 40 | 74 | 77 | 77 | 0 |
| test-plan | `run[].where` | 5 | 9 | 9 | 13 | 13 | 0 |
| test-plan | `support[].file` | 2 | 12 | 12 | 12 | 12 | 0 |
| test-plan | `support[].what` | 2 | 86 | 86 | 161 | 161 | 0 |
| test-plan | `tests[].action` | 14 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `tests[].breaks_on` | 14 | 96 | 121 | 131 | 156 | 0 |
| test-plan | `tests[].file` | 14 | 19 | 19 | 19 | 19 | 0 |
| test-plan | `tests[].guards[]` | 14 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `tests[].id` | 14 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `tests[].level` | 14 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `tests[].name` | 14 | 31 | 47 | 75 | 87 | 0 |
| test-plan | `untested[].case` | 10 | 39 | 53 | 122 | 122 | 0 |
| test-plan | `untested[].id` | 10 | 3 | 3 | 3 | 3 | 0 |
| test-plan | `untested[].proof` | 10 | 8 | 23 | 42 | 42 | 0 |
| test-plan | `untested[].reason` | 10 | 73 | 85 | 130 | 166 | 0 |
| test-plan | `untested[].recommend` | 10 | 4 | 4 | 4 | 4 | 0 |
| test-plan | `untested[].risk` | 10 | 37 | 54 | 93 | 112 | 0 |
| test-plan-challenge | `challenges[].ask` | 15 | 3 | 6 | 6 | 6 | 0 |
| test-plan-challenge | `challenges[].id` | 15 | 3 | 3 | 3 | 3 | 0 |
| test-plan-challenge | `challenges[].target` | 15 | 3 | 3 | 23 | 23 | 0 |
| test-plan-challenge | `challenges[].title` | 15 | 62 | 98 | 139 | 141 | 0 |
| test-plan-challenge | `challenges[].why` | 15 | 181 | 334 | 403 | 532 | 14 |
| test-plan-challenge | `noticed[].at` | 2 | 23 | 23 | 23 | 23 | 0 |
| test-plan-challenge | `noticed[].for` | 2 | 11 | 11 | 11 | 11 | 0 |
| test-plan-challenge | `noticed[].text` | 2 | 158 | 158 | 169 | 169 | 0 |
| test-plan-update | `answers[].answer` | 9 | 6 | 7 | 7 | 7 | 0 |
| test-plan-update | `answers[].id` | 9 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `answers[].reason` | 3 | 194 | 203 | 213 | 213 | 2 |
| test-plan-update | `baseline.gate` | 3 | 4 | 4 | 4 | 4 | 0 |
| test-plan-update | `baseline.note` | 3 | 39 | 39 | 52 | 52 | 0 |
| test-plan-update | `baseline.result` | 3 | 4 | 4 | 4 | 4 | 0 |
| test-plan-update | `baseline.where` | 3 | 16 | 16 | 16 | 16 | 0 |
| test-plan-update | `behaviours[].at` | 13 | 23 | 23 | 26 | 26 | 0 |
| test-plan-update | `behaviours[].guarded_by[]` | 3 | 42 | 53 | 54 | 54 | 0 |
| test-plan-update | `behaviours[].id` | 13 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `behaviours[].text` | 13 | 62 | 101 | 122 | 142 | 0 |
| test-plan-update | `noticed[].at` | 5 | 11 | 11 | 23 | 23 | 0 |
| test-plan-update | `noticed[].text` | 5 | 80 | 96 | 145 | 145 | 0 |
| test-plan-update | `run[].command` | 3 | 74 | 74 | 74 | 74 | 0 |
| test-plan-update | `run[].where` | 3 | 16 | 16 | 16 | 16 | 0 |
| test-plan-update | `support[].file` | 3 | 12 | 12 | 12 | 12 | 0 |
| test-plan-update | `support[].what` | 3 | 77 | 78 | 115 | 115 | 0 |
| test-plan-update | `tests[].action` | 12 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `tests[].breaks_on` | 12 | 108 | 156 | 203 | 218 | 2 |
| test-plan-update | `tests[].file` | 12 | 19 | 19 | 19 | 19 | 0 |
| test-plan-update | `tests[].guards[]` | 13 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `tests[].id` | 12 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `tests[].level` | 12 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `tests[].name` | 12 | 42 | 60 | 66 | 71 | 0 |
| test-plan-update | `untested[].case` | 4 | 45 | 70 | 83 | 83 | 0 |
| test-plan-update | `untested[].id` | 4 | 3 | 3 | 3 | 3 | 0 |
| test-plan-update | `untested[].proof` | 4 | 8 | 8 | 23 | 23 | 0 |
| test-plan-update | `untested[].reason` | 4 | 99 | 167 | 202 | 202 | 1 |
| test-plan-update | `untested[].recommend` | 4 | 4 | 4 | 4 | 4 | 0 |
| test-plan-update | `untested[].risk` | 4 | 112 | 170 | 173 | 173 | 0 |

## Every refusal line, per kind

### build

- build-1, try 1: `decisions[0].at bin/prune-backups.sh option loop names no file in the tree`
- build-1, try 1: `decisions[1].at bin/prune-backups.sh pipeline names no file in the tree`
- build-1, try 1: `decisions[2].at bin/prune-backups.sh verbose output names no file in the tree`
- build-2, try 1: `decisions[0].at bin/prune-backups.sh argument loop names no file in the tree`
- build-2, try 1: `decisions[1].at bin/prune-backups.sh pipeline names no file in the tree`
- build-2, try 1: `decisions[2].at bin/prune-backups.sh usage() names no file in the tree`
- build-2, try 1: `decisions[3].at bin/prune-backups.sh verbose output names no file in the tree`
- build-3, try 1: `decisions[0].at bin/prune-backups.sh, option loop before the arg-count check names no file in the tree`
- build-3, try 1: `decisions[1].at bin/prune-backups.sh, ls | { ... } group names no file in the tree`
- build-3, try 1: `decisions[2].at bin/prune-backups.sh, verbose print names no file in the tree`

### build-fix

No refusal.

### external-review

- external-review-1, try 1: `noticed[0].at description names no file in the tree`
- external-review-2, try 1: `noticed[0].at description names no file in the tree`
- external-review-3, try 1: `noticed[0].at description names no file in the tree`

### test

- test-1, try 1: `decisions[0].at "tests/test_prune.sh: --pattern without a value is a usage error" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-2, try 1: `decisions[0].at "tests/test_prune.sh: --pattern without a value is a usage error" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-2, try 1: `decisions[1].at "tests/test_prune.sh: dry run lists the extra backups and deletes none" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-3, try 1: `decisions[0].at "tests/test_prune.sh: dry run lists the extra backups and deletes none" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-3, try 1: `decisions[1].at "tests/test_prune.sh: --pattern without a value is a usage error" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`

### foreign-review

- foreign-review-3, try 1: `noticed[1].at tests names no file in the tree`

### review

No refusal.

### re-review

No refusal.

### test-fix

- test-fix-2, try 1: `you changed tests/lib.sh, which isn't in the approved plan: undo it, or add a decisions entry at it saying why`
- test-fix-3, try 1: `you changed tests/lib.sh, which isn't in the approved plan: undo it, or add a decisions entry at it saying why`

### test-plan

- test-plan-1, try 1: `behaviours[0].at "bin/prune-backups.sh:24,47-51" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-1, try 1: `behaviours[1].at "bin/prune-backups.sh:25-27,44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-1, try 1: `behaviours[2].at "bin/prune-backups.sh:20,44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-1, try 1: `behaviours[3].at "bin/prune-backups.sh:26,29" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-1, try 1: `behaviours[4].at "bin/prune-backups.sh:23,28" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-1, try 1: `untested[2].proof must be a test, a path:line, or unproven`
- test-plan-2, try 1: `behaviours[1].at "bin/prune-backups.sh:25-27,44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-2, try 1: `behaviours[2].at "bin/prune-backups.sh:20,44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-2, try 1: `behaviours[6].at "bin/prune-backups.sh:11-16,23" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-2, try 1: `untested[1].reason names T-1: say it in words; the IDs are for scripts`
- test-plan-2, try 1: `untested[1].risk names T-1: say it in words; the IDs are for scripts`

### test-plan-challenge

No refusal.

### test-plan-update

- test-plan-update-1, try 1: `behaviours[3].at "bin/prune-backups.sh:26,29" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-update-3, try 1: `behaviours[1].at "bin/prune-backups.sh:25-27,44-46" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-update-3, try 1: `untested[0].proof must be a test, a path:line, or unproven`
