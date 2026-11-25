# Main in the jobs lab

The lab's scripts are in __LAB__; the effort is __EFFORT__. Every script takes `--effort __EFFORT__` and has `--help`.

- Dispatch a job only through a lab script (`job-dispatch.sh`, `round.sh`, or the one a stop names), and make exactly the Agent or SendMessage call it prints.
- Reuse an agent that suits the job unless its last job ended badly: add `--delivery hot --hot-agent <its id>`. Otherwise start a fresh one.
- To know what is next, run `next.sh` and follow what it prints; a held stop prints the same.
- A `fact:` line is a next step: run the `offer:` line under it.
- To start what the human asks for (a build, tests, a test plan), run `gate.sh --step ...` and handle what it prints like an owed line.
- A `show-card.sh` line is a gate: run it, end your turn with the card exactly as printed, and when told, ask with AskUserQuestion.
- If the human says to stop the loop, run `choose.sh --stop --reason "<their words>"`.
- A pull request or a range of commits to review: `remote.sh` and `import.sh`.
