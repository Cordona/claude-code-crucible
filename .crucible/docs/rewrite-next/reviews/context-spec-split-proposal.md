# Proposal: the context and the spec as two phases, each ended at an enforced gate (2026-11-22)

The owner's proposal, with Beta's reading of it. Nothing is decided or authorized. Fable: the owner asks you to review their reasoning.

## The owner's reasoning, in their words, condensed

- No flow for the context phase: the owner agrees with Fable's opinion.
- But before build agents are sent, a specification must be part of what they get. Building the crucible context means drafting what will be cut into a version, and today that version is cut only when an agent is launched, seated or spun off.
- "I insisted on cutting a context version only when the agent is launched, but was this a correct decision, or a wrong one which leaves a phase unfinished and tightly coupled to an entirely different phase?"
- **Instead, cut the context when building it is done.** Main asks at an enforced gate whether the context is done. On a yes, the version is cut and an event written. If something else needs deciding later, another version is cut.
- **Specifying is a separate phase.** After the context is cut, the spec is written from the cut context. If the context must shrink or grow ("we're not ready to specify"), another version is cut.
- So before agents are dispatched or spun off, there are two events: the context and the spec.
- The spec stops being part of context building. That also allows an effort that doesn't need a spec. Both phases end at gates that are enforced by script.

## How it would work (Beta's reading)

- **Context:** the draft grows through discovery, the grill and added entries. At "is the context done?", a recorded gate (record `context-cut`, subject the would-be version's fingerprint). On the human's yes, `context-cut.sh` cuts v<N> and writes `context.cut`. More material later means a new draft, a new gate, and v<N+1>.
- **Spec:** drafted from the newest cut and approved at its own recorded gate (today's `spec-approval`). `spec.approved` gains one field naming the context version it was written from.
- **Dispatch (when built):** requires both events. It refuses when the spec was written from a context that is no longer the newest, and it gives an agent two paths: the context version and the spec.
- **An effort with no spec:** context only. Whether a spec is required becomes the consumer's decision (dispatch), not the context's.

## What changes in the built code (Beta's reading)

- `context-cut.sh`: it requires the human's recorded "context done" answer for the current fingerprint, in place of the fingerprint a dispatch plan pinned. It drops the NO-SPEC and NOT-APPROVED checks.
- `context-fingerprint.sh` / `lib/body.sh`: no spec checks.
- The `context.cut` body: `spec` leaves it (it becomes `{version, paths, links?}`), and `context-verify.sh` stops checking a spec.
- `spec-approve.sh`: it no longer writes `spec.md` into the context's docs folder. It refuses unless a `context.cut` exists, and records its version in `spec.approved`. Where the approved spec file lives (the spec's own folder, sealed) is to be settled.
- The skills' prose: context ends at a gate; the spec is written from the cut version.
- Evidence: context, spec, installed and fixes re-run, with new cases.

## Beta's view

For it. Three gains:
1. **A real end to the context, confirmed by the human.** In run 1 main alone decided discovery was done, and the owner's further thinking spilled into six spec gates.
2. **The one two-way coupling disappears.** Today the cut refuses without an approved spec, and spec approval writes into the context's folder; you recorded that as the one accepted pair. Under this proposal the dependency runs one way: the spec reads the context's event. The consumer, dispatch, reads both.
3. **Efforts without a spec become possible,** with no special case.

The trade-off:
- Cutting at dispatch guaranteed the agent's version was fresh at the moment the plan was approved.
- Under this proposal dispatch must check it is sending the newest version and that the spec matches it. `context-verify.sh` already reports STALE, so the cost is small.

## What Beta asks Fable to judge

1. The owner's reasoning: is cutting at dispatch the wrong coupling the owner suspects, or did it protect something this proposal loses?
2. Two enforced gates (context done, spec approved) against value 16 (weight follows frequency and stakes) and the ceremony concern you raised about the context phase.
3. The one-way dependency: spec on context, dispatch on both. Is that the right direction?
4. Where the approved spec lives once it leaves the context's docs, and how an agent gets it.
5. Anything in the built code or the evidence this would break that Beta's list misses.
6. Whether "an effort without a spec" is a real need or a side benefit.
