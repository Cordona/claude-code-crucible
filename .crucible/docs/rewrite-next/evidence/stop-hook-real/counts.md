# Step 4: counts per kind

Written by `score.sh` from `logs/`. A run is one cell, `<kind>-<n>`. Parked cells are in `parked.md`.

| Kind | Runs | Accepted at the first stop | Repaired after one refusal | Gave up | Other |
|---|---|---|---|---|---|
| build | 2 | 0 | 2 | 0 | 0 |
| review | 2 | 0 | 0 | 2 | 0 |

## Flagged: a line that refused the same kind in 2 runs of 3 or more

- **build** (2 runs): `summary is N characters; shorten it to N or fewer`
- **review** (2 runs): `write your report as one JSON object to <path>`

## Every refusal line, per kind

### build

- trial-build-1, try 1: `decisions[0].at bin/prune-backups.sh option loop names no file in the tree`
- trial-build-1, try 1: `decisions[1].at bin/prune-backups.sh pipeline names no file in the tree`
- trial-build-1, try 1: `decisions[2].at bin/prune-backups.sh loop names no file in the tree`
- trial-build-1, try 1: `noticed[0].at bin/prune-backups.sh pipeline names no file in the tree`
- trial-build-1, try 1: `summary is 168 characters; shorten it to 55 or fewer`
- trial-build-1, try 1: `noticed[0].text is 210 characters; shorten it to 200`
- trial2-build-1, try 1: `decisions[0].at bin/prune-backups.sh, option loop names no file in the tree`
- trial2-build-1, try 1: `decisions[1].at bin/prune-backups.sh, ls pipeline names no file in the tree`
- trial2-build-1, try 1: `decisions[2].at bin/prune-backups.sh, usage() names no file in the tree`
- trial2-build-1, try 1: `decisions[3].at bin/prune-backups.sh, loop names no file in the tree`
- trial2-build-1, try 1: `summary is 186 characters; shorten it to 55 or fewer`
- trial2-build-1, try 1: `decisions[3].why is 203 characters; shorten it to 200`

### review

- trial-review-1, try 1: `write your report as one JSON object to /Users/Shared/crucible-sandbox/stop-hook-real/run/space/efforts/20261125T095104-9b66-real-review-1/reports/review/7.json`
- trial-review-1, try 2: `write your report as one JSON object to /Users/Shared/crucible-sandbox/stop-hook-real/run/space/efforts/20261125T095104-9b66-real-review-1/reports/review/7.json`
- trial2-review-1, try 1: `write your report as one JSON object to /Users/Shared/crucible-sandbox/stop-hook-real/run/space/efforts/20261125T104001-08c8-real-review-1/reports/review/7.json`
- trial2-review-1, try 2: `noticed[0].at 6c7df44d3dbc0bd25ee74abf87d06c36aa9f9859..a6f1b95a7de1d6e8660ea4d7c60a0d2fafe4da9c names no file in the tree`
- trial2-review-1, try 2: `noticed[0].text is 342 characters; shorten it to 200`
