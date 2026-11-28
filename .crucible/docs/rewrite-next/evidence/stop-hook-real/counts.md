# Step 4: counts per kind

Written by `score.sh` from `logs/`. A run is one cell, `<kind>-<n>`. Parked cells are in `parked.md`.

| Kind | Runs | Accepted at the first stop | Repaired after one refusal | Gave up | Other |
|---|---|---|---|---|---|
| build | 3 | 0 | 1 | 2 | 0 |
| build-fix | 3 | 0 | 3 | 0 | 0 |
| external-review | 3 | 0 | 3 | 0 | 0 |
| foreign-review | 3 | 0 | 3 | 0 | 0 |
| re-review | 3 | 0 | 3 | 0 | 0 |
| review | 3 | 0 | 3 | 0 | 0 |
| test | 3 | 0 | 0 | 3 | 0 |
| test-fix | 3 | 0 | 0 | 3 | 0 |
| test-plan | 3 | 0 | 3 | 0 | 0 |
| test-plan-challenge | 3 | 0 | 3 | 0 | 0 |
| test-plan-update | 3 | 0 | 3 | 0 | 0 |

## Flagged: a line that refused the same kind in 2 runs of 3 or more

- **build-fix** (2 runs): `questions[N].text is N characters; shorten it to N`
- **build-fix** (3 runs): `summary is N characters; shorten it to N or fewer`
- **build** (3 runs): `summary is N characters; shorten it to N or fewer`
- **external-review** (3 runs): `noticed[N].at description names no file in the tree`
- **external-review** (3 runs): `noticed[N].text is N characters; shorten it to N`
- **foreign-review** (2 runs): `noticed[N].text is N characters; shorten it to N`
- **foreign-review** (3 runs): `findings[N].claim is N characters; shorten it to N`
- **re-review** (3 runs): `fixes[N].reason is N characters; shorten it to N`
- **review** (2 runs): `notes[N].text is N characters; shorten it to N`
- **review** (3 runs): `findings[N].claim is N characters; shorten it to N`
- **test-fix** (2 runs): `fixes[N].note is N characters; shorten it to N`
- **test-fix** (3 runs): `gates[N].note is N characters; shorten it to N`
- **test-fix** (3 runs): `noticed[N].text is N characters; shorten it to N`
- **test-fix** (3 runs): `summary is N characters; shorten it to N or fewer`
- **test-fix** (3 runs): `summary is N characters; shorten it to N`
- **test-plan-challenge** (3 runs): `challenges[N].why is N characters; shorten it to N`
- **test-plan-update** (2 runs): `behaviours[N].at "bin/prune-backups.sh:N,N" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- **test-plan-update** (2 runs): `untested[N].risk is N characters; shorten it to N`
- **test-plan-update** (3 runs): `answers[N].reason is N characters; shorten it to N`
- **test-plan-update** (3 runs): `C-N asked to add a test and is applied, but no new T- test was added`
- **test-plan-update** (3 runs): `untested[N].reason is N characters; shorten it to N`
- **test-plan** (2 runs): `support[N].what is N characters; shorten it to N`
- **test-plan** (2 runs): `untested[N].proof must be a test, a path:line, or unproven`
- **test-plan** (3 runs): `behaviours[N].at "bin/prune-backups.sh:N-N, bin/prune-backups.sh:N" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- **test-plan** (3 runs): `behaviours[N].at "bin/prune-backups.sh:N, bin/prune-backups.sh:N-N" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- **test-plan** (3 runs): `behaviours[N].at "bin/prune-backups.sh:N, bin/prune-backups.sh:N" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- **test-plan** (3 runs): `noticed[N].text is N characters; shorten it to N`
- **test-plan** (3 runs): `tests[N].breaks_on is N characters; shorten it to N`
- **test** (2 runs): `questions[N].text is N characters; shorten it to N`
- **test** (2 runs): `summary is N characters; shorten it to N`
- **test** (3 runs): `decisions[N].at "tests/test_prune.sh: --pattern without a value is a usage error" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- **test** (3 runs): `gates[N].note is N characters; shorten it to N`
- **test** (3 runs): `summary is N characters; shorten it to N or fewer`

## Every refusal line, per kind

### build

- build-1, try 1: `summary is 215 characters; shorten it to 200`
- build-1, try 2: `summary is 157 characters; shorten it to 55 or fewer`
- build-2, try 1: `decisions[0].at bin/prune-backups.sh, the option loop names no file in the tree`
- build-2, try 1: `decisions[1].at bin/prune-backups.sh, the pipeline names no file in the tree`
- build-2, try 1: `decisions[2].at bin/prune-backups.sh, the loop names no file in the tree`
- build-2, try 1: `summary is 163 characters; shorten it to 55 or fewer`
- build-3, try 1: `decisions[0].at bin/prune-backups.sh argument loop names no file in the tree`
- build-3, try 1: `decisions[1].at bin/prune-backups.sh deletion loop names no file in the tree`
- build-3, try 1: `decisions[2].at bin/prune-backups.sh usage() names no file in the tree`
- build-3, try 1: `summary is 149 characters; shorten it to 55 or fewer`
- build-3, try 2: `decisions[0].choice is 206 characters; shorten it to 200`
- build-3, try 2: `decisions[1].choice is 205 characters; shorten it to 200`

### build-fix

- build-fix-1, try 1: `summary is 166 characters; shorten it to 51 or fewer`
- build-fix-1, try 1: `decisions[0].why is 204 characters; shorten it to 200`
- build-fix-2, try 1: `decisions[1].at "bin/prune-backups.sh:29,33" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- build-fix-2, try 1: `summary is 199 characters; shorten it to 51 or fewer`
- build-fix-2, try 1: `questions[0].text is 203 characters; shorten it to 200`
- build-fix-3, try 1: `summary is 162 characters; shorten it to 51 or fewer`
- build-fix-3, try 1: `questions[0].text is 212 characters; shorten it to 200`
- build-fix-3, try 1: `fixes[2].note is 232 characters; shorten it to 200`

### external-review

- external-review-1, try 1: `noticed[0].at description names no file in the tree`
- external-review-1, try 1: `noticed[0].text is 224 characters; shorten it to 200`
- external-review-1, try 1: `noticed[1].text is 285 characters; shorten it to 200`
- external-review-2, try 1: `noticed[0].at description names no file in the tree`
- external-review-2, try 1: `noticed[0].text is 220 characters; shorten it to 200`
- external-review-2, try 1: `noticed[1].text is 273 characters; shorten it to 200`
- external-review-3, try 1: `noticed[0].at description names no file in the tree`
- external-review-3, try 1: `noticed[0].text is 233 characters; shorten it to 200`
- external-review-3, try 1: `noticed[1].text is 273 characters; shorten it to 200`

### foreign-review

- foreign-review-1, try 1: `findings[0].claim is 267 characters; shorten it to 200`
- foreign-review-1, try 1: `findings[1].claim is 279 characters; shorten it to 200`
- foreign-review-1, try 1: `findings[2].claim is 295 characters; shorten it to 200`
- foreign-review-1, try 1: `findings[3].claim is 268 characters; shorten it to 200`
- foreign-review-1, try 1: `noticed[0].text is 314 characters; shorten it to 200`
- foreign-review-2, try 1: `findings[1].claim is 266 characters; shorten it to 200`
- foreign-review-2, try 1: `findings[3].claim is 263 characters; shorten it to 200`
- foreign-review-3, try 1: `findings[0].claim is 239 characters; shorten it to 200`
- foreign-review-3, try 1: `findings[1].claim is 221 characters; shorten it to 200`
- foreign-review-3, try 1: `findings[3].claim is 277 characters; shorten it to 200`
- foreign-review-3, try 1: `findings[4].claim is 212 characters; shorten it to 200`
- foreign-review-3, try 1: `noticed[0].text is 220 characters; shorten it to 200`

### review

- review-1, try 1: `findings[1].claim is 228 characters; shorten it to 200`
- review-1, try 1: `notes[0].text is 218 characters; shorten it to 200`
- review-2, try 1: `findings[1].claim is 205 characters; shorten it to 200`
- review-2, try 1: `notes[0].text is 221 characters; shorten it to 200`
- review-2, try 1: `notes[1].text is 205 characters; shorten it to 200`
- review-3, try 1: `findings[1].claim is 354 characters; shorten it to 200`
- review-3, try 1: `findings[2].claim is 206 characters; shorten it to 200`

### test

- test-1, try 1: `decisions[0].at "tests/test_prune.sh: --pattern without a value is a usage error" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-1, try 1: `decisions[1].at "tests/test_prune.sh: dry run lists the extra backups and deletes none" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-1, try 1: `summary is 225 characters; shorten it to 200`
- test-1, try 1: `gates[2].note is 678 characters; shorten it to 200`
- test-1, try 1: `questions[0].text is 208 characters; shorten it to 200`
- test-1, try 2: `summary is 128 characters; shorten it to 55 or fewer`
- test-2, try 1: `write your report as one JSON object to /Users/Shared/crucible-sandbox/stop-hook-real/run/space/efforts/20261125T124147-8ed5-real-test-2/reports/test/11.json`
- test-2, try 2: `decisions[0].at "tests/test_prune.sh: --pattern without a value is a usage error" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-2, try 2: `summary is 130 characters; shorten it to 55 or fewer`
- test-2, try 2: `gates[3].note is 497 characters; shorten it to 200`
- test-3, try 1: `decisions[0].at "tests/test_prune.sh: --pattern without a value is a usage error" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-3, try 1: `summary is 245 characters; shorten it to 200`
- test-3, try 1: `gates[2].note is 708 characters; shorten it to 200`
- test-3, try 1: `questions[0].text is 210 characters; shorten it to 200`
- test-3, try 2: `summary is 154 characters; shorten it to 55 or fewer`

### re-review

- re-review-1, try 1: `fixes[1].reason is 447 characters; shorten it to 200`
- re-review-1, try 1: `fixes[2].reason is 325 characters; shorten it to 200`
- re-review-2, try 1: `fixes[1].reason is 393 characters; shorten it to 200`
- re-review-2, try 1: `fixes[2].reason is 501 characters; shorten it to 200`
- re-review-3, try 1: `fixes[1].reason is 427 characters; shorten it to 200`
- re-review-3, try 1: `fixes[2].reason is 500 characters; shorten it to 200`

### test-fix

- test-fix-1, try 1: `summary is 203 characters; shorten it to 200`
- test-fix-1, try 1: `gates[2].note is 497 characters; shorten it to 200`
- test-fix-1, try 1: `noticed[0].text is 528 characters; shorten it to 200`
- test-fix-1, try 1: `fixes[1].note is 269 characters; shorten it to 200`
- test-fix-1, try 1: `fixes[2].note is 232 characters; shorten it to 200`
- test-fix-1, try 2: `summary is 162 characters; shorten it to 52 or fewer`
- test-fix-2, try 1: `summary is 247 characters; shorten it to 200`
- test-fix-2, try 1: `gates[2].note is 334 characters; shorten it to 200`
- test-fix-2, try 1: `noticed[0].text is 448 characters; shorten it to 200`
- test-fix-2, try 1: `noticed[1].text is 216 characters; shorten it to 200`
- test-fix-2, try 1: `fixes[1].note is 284 characters; shorten it to 200`
- test-fix-2, try 2: `summary is 174 characters; shorten it to 52 or fewer`
- test-fix-3, try 1: `summary is 202 characters; shorten it to 200`
- test-fix-3, try 1: `gates[2].note is 341 characters; shorten it to 200`
- test-fix-3, try 1: `noticed[0].text is 412 characters; shorten it to 200`
- test-fix-3, try 2: `summary is 164 characters; shorten it to 52 or fewer`

### test-plan

- test-plan-1, try 1: `behaviours[0].at "bin/prune-backups.sh:24, bin/prune-backups.sh:47-51" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-1, try 1: `behaviours[1].at "bin/prune-backups.sh:25-27, bin/prune-backups.sh:44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-1, try 1: `behaviours[2].at "bin/prune-backups.sh:20, bin/prune-backups.sh:44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-1, try 1: `behaviours[3].at "bin/prune-backups.sh:26, bin/prune-backups.sh:29" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-1, try 1: `tests[0].breaks_on is 330 characters; shorten it to 200`
- test-plan-1, try 1: `tests[1].breaks_on is 327 characters; shorten it to 200`
- test-plan-1, try 1: `tests[2].breaks_on is 477 characters; shorten it to 200`
- test-plan-1, try 1: `tests[3].breaks_on is 289 characters; shorten it to 200`
- test-plan-1, try 1: `support[0].what names T-1: say it in words; the IDs are for scripts`
- test-plan-1, try 1: `untested[1].proof must be a test, a path:line, or unproven`
- test-plan-1, try 1: `noticed[1].text is 247 characters; shorten it to 200`
- test-plan-2, try 1: `behaviours[0].at "bin/prune-backups.sh:24, bin/prune-backups.sh:47-51" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-2, try 1: `behaviours[1].at "bin/prune-backups.sh:25-27, bin/prune-backups.sh:44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-2, try 1: `behaviours[2].at "bin/prune-backups.sh:20, bin/prune-backups.sh:44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-2, try 1: `behaviours[3].at "bin/prune-backups.sh:26, bin/prune-backups.sh:29" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-2, try 1: `tests[0].breaks_on is 348 characters; shorten it to 200`
- test-plan-2, try 1: `tests[1].breaks_on is 302 characters; shorten it to 200`
- test-plan-2, try 1: `tests[2].breaks_on is 350 characters; shorten it to 200`
- test-plan-2, try 1: `tests[3].breaks_on is 259 characters; shorten it to 200`
- test-plan-2, try 1: `tests[4].breaks_on is 215 characters; shorten it to 200`
- test-plan-2, try 1: `tests[5].breaks_on is 258 characters; shorten it to 200`
- test-plan-2, try 1: `support[0].what is 243 characters; shorten it to 200`
- test-plan-2, try 1: `noticed[0].text is 282 characters; shorten it to 200`
- test-plan-3, try 1: `behaviours[0].at "bin/prune-backups.sh:24, bin/prune-backups.sh:47-51" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-3, try 1: `behaviours[1].at "bin/prune-backups.sh:25-27, bin/prune-backups.sh:44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-3, try 1: `behaviours[2].at "bin/prune-backups.sh:20, bin/prune-backups.sh:44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-3, try 1: `tests[0].breaks_on is 307 characters; shorten it to 200`
- test-plan-3, try 1: `tests[1].breaks_on is 332 characters; shorten it to 200`
- test-plan-3, try 1: `tests[2].breaks_on is 249 characters; shorten it to 200`
- test-plan-3, try 1: `tests[4].breaks_on is 252 characters; shorten it to 200`
- test-plan-3, try 1: `support[0].what is 213 characters; shorten it to 200`
- test-plan-3, try 1: `untested[1].proof must be a test, a path:line, or unproven`
- test-plan-3, try 1: `noticed[1].text is 269 characters; shorten it to 200`

### test-plan-challenge

- test-plan-challenge-1, try 1: `challenges[0].why is 407 characters; shorten it to 200`
- test-plan-challenge-1, try 1: `challenges[1].why is 397 characters; shorten it to 200`
- test-plan-challenge-1, try 1: `challenges[2].why is 457 characters; shorten it to 200`
- test-plan-challenge-1, try 1: `challenges[3].why is 727 characters; shorten it to 200`
- test-plan-challenge-1, try 1: `challenges[4].why is 490 characters; shorten it to 200`
- test-plan-challenge-2, try 1: `challenges[0].why is 536 characters; shorten it to 200`
- test-plan-challenge-2, try 1: `challenges[1].why is 710 characters; shorten it to 200`
- test-plan-challenge-2, try 1: `challenges[2].why is 491 characters; shorten it to 200`
- test-plan-challenge-2, try 1: `challenges[3].why is 533 characters; shorten it to 200`
- test-plan-challenge-2, try 1: `challenges[4].why is 846 characters; shorten it to 200`
- test-plan-challenge-2, try 1: `noticed[0].text is 356 characters; shorten it to 200`
- test-plan-challenge-3, try 1: `challenges[0].why is 747 characters; shorten it to 200`
- test-plan-challenge-3, try 1: `challenges[1].why is 523 characters; shorten it to 200`
- test-plan-challenge-3, try 1: `challenges[2].why is 598 characters; shorten it to 200`
- test-plan-challenge-3, try 1: `challenges[3].why is 475 characters; shorten it to 200`
- test-plan-challenge-3, try 1: `challenges[4].why is 402 characters; shorten it to 200`
- test-plan-challenge-3, try 1: `challenges[5].why is 841 characters; shorten it to 200`

### test-plan-update

- test-plan-update-1, try 1: `behaviours[1].at "bin/prune-backups.sh:27,44-46" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-update-1, try 1: `behaviours[4].at "bin/prune-backups.sh:20,44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-update-1, try 1: `tests[0].breaks_on is 315 characters; shorten it to 200`
- test-plan-update-1, try 1: `tests[1].breaks_on is 274 characters; shorten it to 200`
- test-plan-update-1, try 1: `tests[2].breaks_on is 386 characters; shorten it to 200`
- test-plan-update-1, try 1: `untested[0].reason is 375 characters; shorten it to 200`
- test-plan-update-1, try 1: `untested[0].risk is 260 characters; shorten it to 200`
- test-plan-update-1, try 1: `noticed[1].text is 222 characters; shorten it to 200`
- test-plan-update-1, try 1: `answers[2].reason is 334 characters; shorten it to 200`
- test-plan-update-1, try 1: `C-1 asked to add a test and is applied, but no new T- test was added`
- test-plan-update-2, try 1: `tests[0] has unknown key "changes"; an add test's keys are id, action, file, name, level, why, guards, breaks_on`
- test-plan-update-2, try 1: `tests[0].changes is 224 characters; shorten it to 200`
- test-plan-update-2, try 1: `tests[1] has unknown key "changes"; an add test's keys are id, action, file, name, level, why, guards, breaks_on`
- test-plan-update-2, try 1: `tests[1].changes is 267 characters; shorten it to 200`
- test-plan-update-2, try 1: `tests[2] has unknown key "changes"; an add test's keys are id, action, file, name, level, why, guards, breaks_on`
- test-plan-update-2, try 1: `untested[0].reason is 724 characters; shorten it to 200`
- test-plan-update-2, try 1: `answers[2].reason is 317 characters; shorten it to 200`
- test-plan-update-2, try 1: `C-1 asked to add a test and is applied, but no new T- test was added`
- test-plan-update-3, try 1: `behaviours[2].at "bin/prune-backups.sh:26,29" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-update-3, try 1: `behaviours[3].at "bin/prune-backups.sh:19-38,44" is not a location: path, path:N, path:N-M, -path:N or @<where>:path:N`
- test-plan-update-3, try 1: `behaviours[3].text is 217 characters; shorten it to 200`
- test-plan-update-3, try 1: `untested[0].reason is 361 characters; shorten it to 200`
- test-plan-update-3, try 1: `untested[0].risk is 316 characters; shorten it to 200`
- test-plan-update-3, try 1: `answers[2].reason is 292 characters; shorten it to 200`
- test-plan-update-3, try 1: `C-1 asked to add a test and is applied, but no new T- test was added`
