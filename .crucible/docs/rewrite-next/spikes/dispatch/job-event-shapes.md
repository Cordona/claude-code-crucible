# Job event shapes (draft 5; shapes as run in `job-shapes-final.md`)

2026-11-26. Not a spec; the stress test runs on these once the owner approves them.

The owner's model: the adaptive flow is the outline main and the human agree (from the core's step definitions). Each step opens its own gate when its turn comes, and main proposes concrete jobs from what exists then. The human approves jobs, not agents.

Fable's reviews, all applied: `reports/dispatch-shapes-fable.md` (draft 1), `reports/dispatch-shapes3-fable.md` (draft 3).

Every event keeps the envelope `{type, seq, at, by, claude_session_id, body}`. Each shape below is the body. One effort is one repo: a deliberate gap for now; read-only extra folders come later.

## The chain, one example

A build approved at gate 11, then three reviews of it approved at gate 41.

```
seq 11      gate.answered      the human approves the build job
seq 12      job.defined        the build (tree cut from origin/main)
seq 13      tree.cut           job 12's tree
seq 14      agent.initialized  a fresh builder
seq 15      job.assigned       job 12 → that builder, in tree 13
...                            the build is handed in
seq 41      gate.answered      the human approves three review jobs
seq 42..44  job.defined        one per review (tree of job 12)
seq 45      agent.initialized  a fresh security reviewer
seq 46      job.assigned       job 43 → that reviewer, in tree 13
```

## 1. The proposal

Main writes the jobs for one step's gate. A script resolves them into full jobs before the card is shown: the range from job 12's hand-in, the latest context, spec and grills unless main names others, the loop numbers. The card shows the resolved jobs, so the human approves exactly what will run. Only jobs that can start now. Hot or cold is not in it: that is decided at the start.

Which inputs a kind takes is data in the core's step definitions; the resolving script names no kind.

```json
{
  "jobs": [
    {
      "kind": "review",
      "plugins": {
        "language": "kotlin",
        "frameworks": ["spring"],
        "standards": ["clean-code"]
      },
      "tree": {"of": 12},
      "inputs": {
        "context": 17,
        "spec": 22,
        "grills": [9, 14],
        "range": {"base": "<sha>", "head": "<sha>"}
      },
      "loop": {"iteration": 1}
    },
    {
      "kind": "review",
      "plugins": {
        "language": "kotlin",
        "frameworks": ["spring"],
        "standards": ["security"]
      },
      "tree": {"of": 12},
      "inputs": {
        "context": 17,
        "spec": 22,
        "grills": [9, 14],
        "range": {"base": "<sha>", "head": "<sha>"},
        "lens": "security"
      },
      "loop": {"iteration": 1}
    }
  ]
}
```

## 2. gate.answered (core event, one field added)

Today `{accept, answer, accepted}`. Added, generic for every domain: `shown`, what the card showed, by path and hash. An answer approves the whole proposal or none of it.

```json
{
  "accept": true,
  "answer": "Approve",
  "accepted": true,
  "shown": {
    "path": "/…/effort/gates/41/proposal.json",
    "sha256": "<hash>"
  }
}
```

## 3. job.defined (renames job.dispatched)

Written by a script at approval, one per approved job, copied from the resolved proposal in `shown`; it adds nothing. All of a proposal's jobs are defined, or none.

```json
{
  "kind": "review",
  "plugins": {
    "language": "kotlin",
    "frameworks": ["spring"],
    "standards": ["security"]
  },
  "approved": {"gate": 41, "job": 2},
  "tree": {"of": 12},
  "inputs": {
    "context": 17,
    "spec": 22,
    "grills": [9, 14],
    "range": {"base": "<sha>", "head": "<sha>"},
    "lens": "security"
  },
  "loop": {"iteration": 1}
}
```

| Field | Required | Holds |
|---|---|---|
| kind | always | build, test, review, fix…; the kind decides the base agent |
| plugins | always | one language, frameworks if any, at least one standard |
| approved | always | one of three forms, below |
| tree | a job on code | where the agent stands: `{"cut": {"ref": "origin/main"}}` or `{"cut": {"pr": 41}}` for a new tree; `{"of": 12}` for job 12's tree (job 12 must be one that cut; one hop). No `tree`: not on code |
| inputs | by kind, each optional | `context`, `spec`, `grills`, `plan` (seqs of their events); `words` (the human's); `findings`, `sent_back` (ids); `earlier` (entries with ids); `challenges`; `lens`; `range` {base, head}; `threads` (path); `foreign` (the MR); `known_failures` (names) |
| loop | by kind | `iteration`, computed by the rule |

The three forms of `approved`:

```json
{"gate": 41, "job": 2}
```

The human's answer at gate 41, the second proposed job.

```json
{"gate": 57, "round": 2}
```

A fix loop's round, run unattended after the fix-targets gate 57. The fix-targets proposal holds only the first fix, as `{"gate": 57, "job": 1}`; every job after it in that loop is `{"gate": 57, "round": N}`, the first re-review being round 1. Checked: the job is a fix for findings chosen at gate 57, or a review judging those findings again; the round is within the cap; the previous round's reviews are in. Otherwise refused: "a gate is needed". Main picks each round's jobs, in the proposal shape, with no card.

```json
{"replaces": 44}
```

An ungated replacement for a dead or unreachable agent: a copy of job 44, only the agent is new; the one choice is to continue in its tree or cut anew.

A reviewer stands in a tree read-only: the build's (`of`) when the build is in this effort, or one cut for the review (from a PR or ref) when it isn't: a foreign MR, code from another effort, an effort that starts with a review.

Changes from job.dispatched: `agent_type` dropped (the kind decides it); `setup` is now `plugins`; `report` dropped (always `reports/<kind>/<seq>.json`); `approved` is new; `tree` says what to cut or whose tree (the path is in tree.cut); `known_failures` moved into inputs; inputs point to events by seq; `fix_round` replaced by `approved.round`. The iteration rule's key changes from the tree's path to the job that cut it.

## 4. tree.cut (new)

Written by the tree script, once per job whose `tree` is `cut`.

```json
{
  "job": 12,
  "path": "/…/effort/trees/t3",
  "commit": "<sha the tree starts at>",
  "branch": "job-12"
}
```

## 5. agent.initialized

Written by the one start-hook entry, once per agent; a resume writes none. `base` and `plugins` are read from the agent file's frontmatter; nothing reads meaning out of `type`.

```json
{
  "agent": "a07d3d2622ec2f71c",
  "base": "code-reviewer",
  "type": "reviewer-kotlin-spring-security",
  "plugins": [
    "language-kotlin",
    "language-kotlin-review",
    "framework-spring",
    "framework-spring-review",
    "standard-security"
  ]
}
```

## 6. job.assigned

"This job, to this agent, in this tree." `tree` is the seq of the tree.cut it stands in. Cold: written by the start hook. Hot: written after main's message is sent, not by the door.

```json
{
  "job": 43,
  "agent": "a07d3d2622ec2f71c",
  "tree": 13
}
```

## Who writes what

Main judges only what to propose and hot or cold. Main never writes an event.

| Step | Done by | Main's part |
|---|---|---|
| Resolve the proposal; the gate card | scripts, from main's jobs | writes the jobs |
| Agent files for the proposed kind+sets | its own script, at the gate; leftovers from a rejected proposal are accepted | none |
| `job.defined` | a script, all approved jobs at once (a fix round: main's jobs, checked) | runs it |
| `tree.cut` | the tree script, all at once | runs it |
| The start | the door checks and prints the exact Agent call (cold) or SendMessage (hot), for every ready job in one run | sends one per reply |
| `agent.initialized`, `job.assigned` (cold) | the start hook | none |
| `job.assigned` (hot) | after the message is sent | none |
| Drop a job never started | `end-job.sh`, with main's note (exists today) | runs it |

Each script prints a result and what is still needed ("job 44 defined; its tree isn't cut"), never the next command of a fixed sequence. A step is over when its jobs have ended: a reading of the log, no new event.

## The invariants (eight)

1. A job traces to an approved proposal entry, to its fix loop's gate within the cap, or to the job it replaces.
2. A job is assigned once; an agent holds one open job.
3. A job on code has its tree before its agent starts.
4. Its plugins exist and are loadable.
5. One job agent per reply.
6. A start is the door's call.
7. A hot agent: same base, and its plugins cover the job's.
8. A tree holds at most one open writing job: the door refuses a second. A reader beside an open writer gets one line ("tree 8 has an open build, job 37") and main decides. (Owner, 2026-11-26.)

Everything else is main's: what to propose, the order, hot or cold, messaging an agent mid-job, starting over.

## Open, small

- `lens` and `standards` can say the same thing (security); whether a review needs both.
