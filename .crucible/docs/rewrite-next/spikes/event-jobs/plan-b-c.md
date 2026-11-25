# Spike: Stage A result and the plan for B and C (2026-11-24)

By Dev Beta, for the Crucible Fable Reviwer. The owner asks that we align, so that the spike gives enough confidence and knowledge to build the real thing. Talking only.

## Stage A: done

- **72 of 72 pass:** `evidence/stage-a.out`.
- **Independent authors:** one agent wrote the cases from the spec, the contract and your answers, and your check was applied. A second agent wrote the scripts and could not edit a case. No case was disputed. A grep finds no case names or literal seqs in `lab/`.
- **What the script agent noted:**
  - the report path is guessed before the event's seq exists, a race;
  - the arbiter gets no insist reason, because no event carries it;
  - the scan rules are one `owes.jq`, not split per component;
  - `main-stop.sh`, `remote.sh` and `import.sh` are not built yet.

## The owner's realism question

**The events are the job model's proposed real types, but written by the lab's stand-in `ev.sh`,** not by new-rewrite's `crucible-events` writer. That writer has per-type rules, "written only by" checks, refusal on a damaged log and the exit-6 lock cases. And the job events never sit beside real `flow.*` or gate events.

**Proposal:**
- **The lab writes through a copy of the real writer.** For Stage B and C, the lab gets a copy of new-rewrite's `crucible-events` component, with per-type rules for the new types. New-rewrite itself is not touched.
- **`ev.sh` becomes a thin adapter onto it.** Stage A re-runs through the adapter, so the cases prove the real writer accepts every event the lab writes.
- **The race goes:** the writer fills the report path in under its lock.
- **The rules become the first draft of the real rules.**

## The rest of B and C, as in spec.md

- **To build:**
  - `main-stop.sh`, with its one-line `owed:` and `fact:` forms;
  - `remote.sh`, the fake PR;
  - `import.sh`;
  - `driver.sh`, the dry run through the real hooks for every C run;
  - `main.md`, at most 25 lines;
  - the sandbox, with its own config folder and tmux.
- **To run:** Stage B, headless hook cases. Then the driver's dry run per C run, then C1 ×2, C2 ×3, C3 to C6, C10, and C7 to C9 last.

## What we ask

1. **Is the real writer the right step toward realism?** Should the spike also use other real pieces:
   - core's gate, so `gate.answered` is the gate's own event;
   - the adaptive flow's events, so facts meet an agreed flow;
   - git-worktree's cut, for the trees?

   Or does that turn the spike into the build?
2. **After B and C pass, what would still keep us from building the real thing with confidence?** Is there an experiment, cheap now and expensive later, that we should add? For example:
   - one live run with a real reviewer agent on real code, to test job discipline under judgement;
   - a permission-mode run, to see how a prompt stalls an unattended loop.
3. **Anything in the Stage A result to doubt** before we build on it?

Please write your answer to `plan-b-c-fable.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
