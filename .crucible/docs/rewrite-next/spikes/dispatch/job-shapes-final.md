# Job events: the chain and the shapes

## What happens, what is emitted

```
WHAT HAPPENS                                         EMITTED             BY
─────────────────────────────────────────────────────────────────────────────────────────
A step of the adaptive flow comes up.
Main proposes jobs; a script resolves them;
the card shows them; the agent files are written.    (nothing)
The human approves.                                  gate.answered       card script
Each approved job is written down.                   job.defined  × N    define script
Each job that needs a new tree gets one.             worktree.cut × M    worktree-cut.sh

COLD (a fresh agent), one per message:
  Main sends the Agent call the door printed.
  Claude Code makes the agent; its tree is answered.
  The agent starts, plugins loaded.                  agent.initialized   start hook
  The job is linked to it and its tree.              job.assigned        start hook

HOT (an agent that already exists):
  Main sends the message the door printed.           job.assigned        after the send

The agent works and hands in its report.             <kind>.submitted    stop hook

FIX LOOP (after the fix-targets gate, no human):
  Main picks the round's jobs; checked against
  the chosen findings and the cap.                   job.defined         define script
  ... then cold or hot, as above.
  Past the cap or outside the findings: refused,
  "a gate is needed".

A DEAD AGENT:
  Its job is ended, a copy is defined.               job.ended
                                                     job.defined         define script
  ... then cold, as above.

A JOB NEVER STARTED:
  Main drops it with a note.                         job.ended           end-job script

A TREE ALREADY HAS AN OPEN WRITING JOB:
  A second writing job: the door refuses it.         (nothing)
  A reader: the door says "tree 13 has an open
  build, job 37"; main decides.                      (nothing)

A BAD "CUT FROM":
  The tool refuses at the cut; the job has no tree;
  main drops it and proposes again.                  job.ended           end-job script
```

## The example log

```
seq 11      gate.answered      build approved
seq 12      job.defined        the build
seq 13      worktree.cut       job 12's tree
seq 14      agent.initialized  a fresh builder
seq 15      job.assigned       job 12 → builder, tree 13
seq 20      build.submitted    the build handed in
seq 41      gate.answered      three reviews approved
seq 42..44  job.defined        the reviews
seq 45      agent.initialized  a fresh security reviewer
seq 46      job.assigned       job 43 → reviewer, tree 13
```

## 1. The proposal (resolved)

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
    },
    {
      "kind": "review",
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
  ]
}
```

## 2. gate.answered (existing event, unchanged)

```json
{
  "accept": true,
  "answer": "Approve",
  "accepted": true,
  "record": "jobs",
  "subject": "<sha256 of the resolved proposal>"
}
```

## 3. job.defined

A review, on an existing tree:

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

A build, cutting a new tree (no range yet: its commits make it):

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

`approval_gate`, its forms:

On a card:

```json
{
  "approval_gate": {
    "ref": 41,
    "position": 2
  }
}
```

A fix-loop job (no card; the fix-targets gate; its round in `work.loop`, its targets by ref):

```json
{
  "approval_gate": {
    "ref": 57
  },
  "input_refs": {
    "fix_targets": 58
  },
  "work": {
    "loop": {
      "round": 1,
      "iteration": 2
    }
  }
}
```

A replacement (the original's gate, plus the link):

```json
{
  "approval_gate": {
    "ref": 41,
    "position": 2
  },
  "replaces": 44
}
```

## 4. worktree.cut (existing event, unchanged)

```json
{
  "name": "job-12",
  "repo": "/…/repo",
  "path": "/…/effort/worktrees/job-12",
  "branch": "crucible/<effort>/job-12",
  "base": "<sha>",
  "from": "ref:origin/main"
}
```

A tree merged from two trees:

```json
{
  "name": "job-30",
  "repo": "/…/repo",
  "path": "/…/effort/worktrees/job-30",
  "branch": "crucible/<effort>/job-30",
  "base": "<sha>",
  "from": "worktree:job-12 worktree:job-20",
  "signed": true
}
```

The job's tree, its two forms:

```json
{
  "cut": {
    "repo": "/…/repo",
    "from": "worktree:job-12 worktree:job-20"
  }
}
```

```json
{
  "use": 13
}
```

## 5. agent.initialized

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

```json
{
  "job": 43,
  "agent": "a07d3d2622ec2f71c",
  "tree": 13
}
```

Every event is wrapped in the same envelope:

```json
{
  "type": "job.assigned",
  "seq": 46,
  "at": "2026-11-26T17:40:12Z",
  "by": "start-hook",
  "claude_session_id": "<main session id>",
  "body": {
    "job": 43,
    "agent": "a07d3d2622ec2f71c",
    "tree": 13
  }
}
```
