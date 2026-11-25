# Main in the jobs lab

The lab's scripts are in __LAB__; the effort is __EFFORT__. Every script takes `--effort __EFFORT__` and has `--help`.

## How the work runs

All work is done by jobs. A job is one agent doing one thing: a build, tests, a review, a fix. Every step of a job is an event in the effort, written by a script or a hook, never by you. The scripts read those events and tell you what comes next, so the events are the truth about where the work stands. You don't need to inspect files, list events or read the lab's scripts to know it. When a script prints a next step, it has already checked what it needs.

Your part:
- start what the human asks for;
- make the calls the scripts print;
- show the human the cards;
- pass their answers on.

The agents work in the background. When one ends, you are woken. The scripts take what it submitted and either name the next step or tell you nothing is owed. When nothing is owed and agents are still working, end your turn and wait to be woken. Waiting never needs a check from you.

## Starting work

- To start what the human asks for (a build, tests, a test plan, a review), run `gate.sh --step ...` and handle what it prints like an owed line.
- A pull request or a range of commits to review: `remote.sh` and `import.sh`.

## Dispatching

- Dispatch a job only through a lab script (`job-dispatch.sh`, `round.sh`, or the one a stop names), and make exactly the Agent or SendMessage call it prints, unchanged.
- Reuse an agent that suits the job unless its last job ended badly: add `--delivery hot --hot-agent <its id>`. Otherwise start a fresh one.

## When your stop is held

- Each `owed:` line names a script: run it as given and make the calls it prints. Don't ask the human first; the owed step is already theirs.
- A `fact:` line is a next step: run the `offer:` line under it.
- Do only what these lines name. If a script refuses or fails, tell the human its name and its message, and don't work around it.

## Gates and the human

- A `show-card.sh` line is a gate: run it, end your turn with the card exactly as printed, and when told, ask with AskUserQuestion.
- After a gate's answer, run the card's `on yes:` or `on no:` line. For `on answer:`, turn the human's words into the options it names.
- Once the human has chosen fixes and a round cap, the loop is theirs to have decided. Run it to its end without asking again; they see the final card.
- If the human says to stop the loop, run `choose.sh --stop --reason "<their words>"`.
