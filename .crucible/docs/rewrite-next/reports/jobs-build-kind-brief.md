# The build kind: folder layout (for Fable, final alignment before building)

2026-11-27. The owner has given the go to build this once you align. It follows your job-kinds opinion (`reports/job-kinds-fable.md`) and the owner's decisions since.

## Owner's decisions (settled)

- One `job.defined` event; one piece per kind; all of them write `job.defined` through one shared define script.
- All job machinery in the software domain: `domains/software-development/core/main-thread/jobs/`.
- A kind's job facts (what a job of that kind needs) live in the job's folder, not in `submissions/`. Submissions stay what the agent hands in.
- Kinds stay separate where their reports differ: review / foreign-review / external-review-verdict; test-plan / test-plan-update (correlated through the jobs' `input_refs`).
- Shapes as in `spikes/dispatch/job-shapes-final.md` and `specs/jobs-1-defined.md` (fix loop: `approval_gate {ref}`, `input_refs.fix_targets` → `fix.chosen`, `work.loop {round, iteration}`).

## Proposal: build only, everything else untouched

```
software-development/core/
├── main-thread/
│   └── jobs/
│       ├── job-define/                 shared by every kind
│       │   ├── events/
│       │   │   └── job.defined.jq      the one rule: the frame + counts
│       │   └── scripts/
│       │       ├── main/
│       │       │   ├── job-resolve.sh  main's proposal → full jobs
│       │       │   └── job-define.sh   writes job.defined × N
│       │       └── lib/
│       │           └── job-frame.jq    approval_gate, plugins, input_refs, work
│       └── build/                      the build kind
│           ├── SKILL.md                thin prose: when main proposes a build
│           └── job.json                what a build job needs
└── agents/
    └── code-builder/
        └── submissions/
            └── build.json              what the builder hands in (writes removed)
```

`jobs/build/job.json`:

```json
{
  "input_refs": {
    "context": "context.cut",
    "spec": "spec.approved",
    "grills": "grill.ended"
  },
  "tree": ["cut", "use"],
  "write_scope": "tree"
}
```

`agents/code-builder/submissions/build.json` after:

```json
{
  "event": "build.submitted",
  "commit": true,
  "rules": "code-builder/scripts/lib/build-report",
  "problems": "build_report_problems"
}
```

The move: `writes` leaves submissions as `write_scope` in `jobs/<kind>/job.json`; `agents/agent-submission/hooks/pre-tool-use/steps/write-scope.sh` reads it from there. Until the other kinds move, the hook falls back to `submissions/<kind>.json`'s `writes` (removed when the last kind moves). `agent-jobs/` (dispatched, assigned, ended, iteration.jq) stays for now; its `kind == "build"` in iteration.jq becomes a declared fact later, not in this step.

## Questions

1. Layout and the split (job facts vs submission facts): aligned?
2. `job.json`'s fields: right and enough for build? Required vs optional refs (a build with no spec or no grills)?
3. The hook reading from `jobs/`: an agent-side piece now reads a main-thread folder. Acceptable coupling, or should the job's write scope travel in the job event the hook already finds?
4. The temporary fallback: fine, or move all kinds' `writes` at once?
5. `SKILL.md` per kind: does main load it, or is it reached another way (your "folder first" lean)?

Reply to Crucible Dev Beta; write it to `reports/jobs-build-kind-fable.md`. Architecture only.
