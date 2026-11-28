# F3: the interactive set (tmux, the owner's mode)

`claude --permission-mode default --model sonnet`, started in the repo, inside tmux (`lab/interactive.sh`). The allow-list and the stubs are the same as headless. I answered as the human, and every key is logged in `logs/_sessions/<cell>-<suffix>/keys.txt`, with the pane snapshots in `panes.txt`.

| Cell | Outcome | What reached the human | Keys |
|---|---|---|---|
| `i-build` (run `-i`) | **refused once and repaired.** The refusal: four `decisions[N].at bin/prune-backups.sh <words> names no file in the tree`. Then `build.submitted`. Lint, typecheck and test ran | (1) `sh -c '<a scratch-folder manual run of --verbose in mktemp>'`, "This command requires approval", a plain single command reaching the human; (2) `sed -i … reports/build/4.json`, the agent repairing its own report, "Do you want to proceed?" | `1` (Yes) to both |
| `i-review` (run `-i`) | **accepted at the first stop.** A finding in `bin/prune-backups.sh` | nothing | none |
| `i-parked-build` (run `-ip`) | **repaired**, after a location refusal. It didn't park; see `parked.md` | the same kind of scratch-folder `sh -c` manual run | `1` |

**The compound command refused by the real hook, in `i-build`:**
- The PermissionRequest hook `deny-compound-commands.sh` answered 5 of the agent's asks with `deny`: "Run it as plain single commands, one per call. Your other commands still run."
- They were `cd <tree> && …` forms, seen in `logs/i-build/hooks/PermissionRequest-*`. The human was never shown them.
- Its two other calls gave no decision, and those are the two asks above, which reached the human.

**The checks** (`score.txt`), for `i-build`, `i-review` and `i-parked-build`:
- Opus;
- the exact prompt;
- no tracker call by the agent;
- R3: no message from main between the refusal and the submission;
- the planted fact, for the review;
- the allowed gates run, for the builds;
- the frozen hash;
- the audit.

All pass, but for `i-parked-build`'s parked expectation.

**The client's own `gh auth token`** at start-up doesn't count, as the brief says. The scorer counts only the agent's own Bash calls, and the agents made none.
