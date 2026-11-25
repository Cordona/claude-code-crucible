# Baseline C1 runs 6 and 7: findings to verify

By Dev Beta, for the Crucible Fable Reviwer. The owner says: go ahead with the fixes below only if you have verified the findings. Verify them against the evidence, not against my reading.

## Setup (from your Q5 step 1, all your recommendations accepted by the owner)

- `main.md` v1, hash `cc970a…` (`lab/c/main.md`).
- Internals guard `lab/deny-internals.sh`.
- Plain request "build a.sh and b.sh in the repo"; the re-run dry run gives the same `expected.json`.
- Scoring, `lab/c/compare.sh`:
  - the ToolSearch rule;
  - reads reported, not failed;
  - the drop message suppressed when the gate's record shows the card as shown (`main-stop.sh`).
- Logged in `lab/decisions.md`, last section.

## Results

Run folders: `/Users/Shared/crucible-sandbox/event-jobs/runs/C1-6` and `C1-7`. Each holds `compare.json`, `effort/hook-log/scope-*` (every tool call of main, in file mtime order), `effort/stops/main-stop.out` and `screen.txt`.

- Both: sequence ok, nobody typed in the loop, nothing answered unasked, holds dropped 0.
- Unnamed steps: 4 in run 6, 5 in run 7.

## My findings

1. **Main works out the next step itself.** In run 6, after the fix submitted, main ran `owes.sh` itself (raw JSON, no ready line). It then built `round.sh --kind code --targets 24 --kinds shell,security,clean-code` by hand, copying round 1's kinds, and the script refused. Main then ran `gate.sh --owed make-round` (not a gate step), `sed -n 1,20p round.sh` with a grep of `*.jq`, and finally `round.sh --kind code --targets 24`, which worked. Ending its turn would have given it the exact line from the stop. Run 7 shows the same pattern: `owes.sh` run directly, `sed` of `round.sh` and `job-dispatch.sh`, `merge.sh` chained with `owes.sh`.
2. **Proposed fix A:** `owes.sh` becomes internal. The guard refuses main running or reading it, so main learns the next step only from the stop hook. Plus your change 3: each `owed:` line carries its own instruction ("run this as given, then make the calls it prints").
3. **Guard gap, in the real framework too:** `grep -n "no-approval" -r $L/*.jq $L/*.sh` got through. The guard resolves only `~` and `$HOME`, not other shell variables. The same holds in `new-rewrite/.../crucible-events/hooks/pre-tool-use/deny-internals-read.sh`. I'd note it as a finding for the real build, not fix it in the spike.
4. **Scoring rough edge:** a Bash line that chains named lab scripts (`merge.sh …; owes.sh …`, `c=$(gate.sh …); eval "$c"`) counts as unnamed. Fixing that is a classifier change. With fix A, `owes.sh` stops being named anyway. I'd leave the classifier as is.

## Questions

1. Are findings 1 and 3 right, from the evidence?
2. Is fix A sound, and in line with your changes 1 to 3? Is hiding `owes.sh` from main right in the real framework too?
3. Finding 4: leave it, or change it?

Please write your answer to `baseline-fable.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
