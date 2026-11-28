# Jobs, step 1: the job defined (built 2026-11-27, for the owner's review)

2026-11-26, built 2026-11-27. First of six steps (defined, agent, tree, assigned, loop, reader). Proven in `spikes/dispatch/` (stress runs); shapes approved in `job-shapes-final.md` except where this draft changes them (marked). Principles: floating pieces, loosely coupled, cohesive, one act per script, DRY, simple.

## What this step does

Main proposes jobs for one step's gate; a script resolves them into full jobs; the card shows them; the human answers; a script writes one `job.defined` per approved job. Main writes no event.

## Where it lives

All in the software domain; the core is unchanged except the installer (owner, 2026-11-27). Everything about defining a job is in one folder, `domains/software-development/core/main-thread/jobs/define/`, installed as `jobs-define`:

```
jobs/define/
├── SKILL.md            thin prose for main
├── kinds/build.json    a kind: agent, input refs, tree forms, write scope
├── events/job.defined.jq
└── scripts/
    ├── main/           job-resolve.sh, job-card.sh, job-define.sh
    └── lib/            job-frame.jq (shapes, the iteration count), job-resolve.jq
```

`jobs/` is a group: a folder holding only components. The installer links each member as GROUP-NAME (`jobs-define`; later `jobs-assign`), and allows a `kinds/` folder; both are generic, naming no domain. Adding a kind adds `kinds/KIND.json` and edits nothing else. No script names a kind, except the iteration count's `kind == "build"` (to settle before the second kind moves: a rule can't read a kind's file).

The write scope moved: `kinds/build.json`'s `write_scope`; `code-builder/submissions/build.json` lost `writes`. `agent-jobs`' `agent-job.sh` returns the scope with the job (the kind's file, else its submissions file for a kind not moved yet); the write-scope hook reads it from there.

After this step nothing consumes `job.defined`: the door, assign and the submission rules still key on `job.dispatched`.

## Shape change (for the owner)

Owner-approved 2026-11-27 (`job-shapes-final.md`): `approved` becomes `approval_gate` (`ref` + `position` on a card, `ref` alone in the fix loop, whose round is in `work.loop`; a replacement copies the original's and adds `replaces`); `inputs` becomes `input_refs`, seqs only; `lens` dropped (it repeated `plugins.standards`); `tree`, `range` and `loop` grouped in `work`.

```json
{
  "kind": "review",
  "approval_gate": {
    "ref": 41,
    "position": 2
  },
  "plugins": {
    "language": "kotlin",
    "frameworks": ["spring"],
    "standards": ["security"]
  },
  "input_refs": {
    "context": 17,
    "spec": 22,
    "grills": [9, 14]
  },
  "work": {
    "tree": {
      "use": 13
    },
    "range": {
      "base": "<sha>",
      "head": "<sha>"
    },
    "loop": {
      "iteration": 1
    }
  }
}
```

A build whose tree doesn't exist yet: `cut` says where to cut it from. The tree is cut after this event, and its `worktree.cut` links back to the job. No `range` yet: the build's commits make it.

```json
{
  "kind": "build",
  "approval_gate": {
    "ref": 11,
    "position": 1
  },
  "plugins": {
    "language": "kotlin",
    "frameworks": ["spring"],
    "standards": ["clean-code"]
  },
  "input_refs": {
    "context": 17,
    "spec": 22,
    "grills": [9, 14]
  },
  "work": {
    "tree": {
      "cut": {
        "repo": "/…/repo",
        "from": "ref:origin/main"
      }
    },
    "loop": {
      "iteration": 1
    }
  }
}
```

Other trees a job can cut (each `work.tree`; all cut after `job.defined`; only `worktree:` repeats; a bad `from` is refused at the cut and main drops the job):

Merged from two builds:

```json
{
  "cut": {
    "repo": "/…/repo-a",
    "from": "worktree:job-12 worktree:job-20"
  }
}
```

On top of another build's tree:

```json
{
  "cut": {
    "repo": "/…/repo-a",
    "from": "worktree:job-12"
  }
}
```

From a branch or a PR head (code not from this effort):

```json
{
  "cut": {
    "repo": "/…/repo-b",
    "from": "ref:origin/feature/login"
  }
}
```

From the human's checkout, uncommitted changes included:

```json
{
  "cut": {
    "repo": "/…/repo-c",
    "from": "snapshot"
  }
}
```

From the checkout's commit, without uncommitted changes:

```json
{
  "cut": {
    "repo": "/…/repo-c",
    "from": "checkout"
  }
}
```

A fix in round 1. At gate 57 the human chose the fix targets; that choice is the `fix.chosen` event (seq 58, all the targets). Main then defines the fix with no card; it traces to gate 57 and takes its targets by ref. In round 2 and later the targets ref is the re-review's `review.merged` (its targets still open). The loop holds the round and the tree's iteration (the build was 1).

```json
{
  "kind": "fix",
  "approval_gate": {
    "ref": 57
  },
  "plugins": {
    "language": "kotlin",
    "frameworks": ["spring"],
    "standards": ["clean-code"]
  },
  "input_refs": {
    "context": 17,
    "spec": 22,
    "grills": [9, 14],
    "fix_targets": 58
  },
  "work": {
    "tree": {
      "use": 13
    },
    "loop": {
      "round": 1,
      "iteration": 2
    }
  }
}
```

`range` is in `work`: it comes from the tree, so only a `use` job has one when defined.

No change to `gate.answered`: it already has `subject` ("what exactly is decided, e.g. a sha256"). The card's `--subject` is the resolved proposal's sha256; `shown` is dropped.

## The pieces

| Piece | One act | Writes |
|---|---|---|
| `job-resolve.sh --effort E --jobs FILE` | main's `{jobs: [{kind, plugins, work: {tree}, input_refs?}]}` made full: each ref the kind declares filled from the log (latest event, every one for a list) unless named; the tree's form checked against the kind; the iteration counted. All or none, one line per fault. Two builds on one tree in one proposal: refused | `E/proposals/<sha256>.json`; prints "N jobs resolved: PATH, sha256 SHA" |
| `job-card.sh --effort E --proposal FILE` | the card, one line per job, shown through `show-card.sh --record jobs --subject <sha256> --accept 'Approve (Recommended)'` | `E/proposals/<sha256>.card.md`; the owed card |
| `record-gate-answer.sh` (exists) | the human's answer | `gate.answered` |
| `job-define.sh --effort E --gate SEQ` | the gate is a jobs gate, accepted, not yet defined; the file named by its `subject` exists and is unchanged; then one `job.defined` per job, in order; a refusal stops the rest and names those written | `job.defined` × N |
| `job.defined.jq` | written only by `job-define.sh`; `approval_gate` an accepted jobs gate, each ref+position once; plugins; `input_refs` earlier events' seqs; `work.tree` a worktree.cut or a cut; `range` only with `use`; a build's iteration the next on its tree (the stale race, checked at the write) | |

A build's iteration: 1 on a tree it cuts; on a tree it uses, 2 plus the builds already defined on it. That counts the cutting job as the tree's first build: right for a build's tree, and settled properly in step 3 (trees), where a cut links to its job.

The card is a path and one line per job; its full content (findings, the human's decision) is a later step. This step alone is not what the human will use.

## What main reads back

Each script prints a result and what is still needed, never the next command:
- `job-resolve.sh`: "3 jobs resolved: PATH, sha256 X", or one line per fault ("job 2: kind \"reveiw\" is not a kind; kinds: build", "job 1: a build needs context: there is no context.cut yet").
- `job-define.sh`: "jobs 9, 10, 11 defined", then "job 9: its tree is still to be cut, in REPO from FROM"; or "the card showed X, the file is now Y: resolve again".

## Not built in this step

- The fix loop's form (`approval_gate {ref}`, `work.loop.round`, `input_refs.fix_targets` → `fix.chosen`) and a replacement (`replaces`): step 5 and the dead-agent case. The rule refuses them today.
- A `SKILL.md` per kind: added when a run shows main lacking it (Fable).
- A flow step for defining jobs in the adaptive flow's catalogue.

## Validation (run)

`evidence/jobs-1/run.sh`, installed layout, real grill, context cut, spec and tree, the gate answered through the installed hooks: 33 passed, 0 failed (`evidence/jobs-1/run.out`).

1. Three builds resolve, show, are approved and defined; one gate.answered with the proposal's sha256, three job.defined equal to the proposal entries plus their approval_gate.
2. One wrong job refuses the whole proposal, every fault on its own line, nothing written.
3. The proposal changed after its card: define refuses.
4. A gate's jobs defined twice: refused.
5. A rejected gate: define refuses, nothing written.
6. The stale case: two proposals with a build on one tree; the second refused at the write with the iteration it should have.
7. No spec and no grills resolves; no context is refused, the line saying what is missing.
8. Two builds on one tree in one proposal: refused.
9. Only job-define.sh writes job.defined.
- The core has no job word; job-define names no agent.
- Regression after the write-scope move: agent-jobs 69/69, build-agent 397/397 (a builder's write outside its tree still denied; the missing-scope case updated), test-agent 110/110 and review-agent 112/112 (kinds not moved, still scoped from `submissions/`).

## Not in this step

Agent files and plugins (step 2), trees (3), assignment and the door (4), the loop's checks (5), the reader (6).
