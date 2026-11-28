# The context, the grill and the spec as three facts: decisions for review (2026-11-22)

The owner's decisions after the discussion in `context-spec-split-proposal.md` and the review rounds that followed. Fable: the owner asks you to confirm them. Nothing is built.

## Decided by the owner

1. **Three independent facts, each its own phase.**
   - **Context:** outside files (absolute paths), links, native Claude Code tasks, tracker copies, notes. When the human says it's done, it's cut, and the cut writes `context.cut` (enforced: below).
   - **Grill:** independent of the context. When it ends, it writes `grill.ended`, as today.
   - **Spec:** written from the cut context and the grill(s), if they exist. Approved at its recorded gate, it writes `spec.approved`, which names the approved file.
   - None of the three knows the others. The spec no longer lives in the context's docs, and grill paths are no longer added to the context.
2. **The context is cut at a recorded "done?" gate,** not at dispatch. A recorded gate whose subject is the draft's fingerprint; `context-cut.sh` refuses without the human's newest yes on that fingerprint. If the context moves later: another gate, another version. An empty context may be cut.
3. **Cards stay free-form, written by main,** context "done?" included: concise, with the draft's absolute path and main's recommendation. The fingerprint, not the card, guarantees that what is cut is what the human said yes to: the cut refuses if the draft changed since the yes. Cards are computed from a source only where the source is the point: build, test and review reports, and the spec, whose draft is its card. **No new card-rendering scripts.** Whether `flow-card.sh` stays is open.
4. **Absence is organic, and only the human judges it.** An effort may have no context event (the facts lived in the conversation), no grill, even no spec, because none was naturally created. So **spec approval does NOT require a context cut** (this reverses the recommendation in your last opinion). No script can tell "organically absent" from "main forgot". The human tells them apart at the dispatch plan, which lists each input and marks a missing one as "none".
5. **Agents get event paths.** The dispatch or spin-off logic harvests the events and gives each agent absolute paths to them. The agent reads the event and follows the path in its body: the version, the spec file; a grill's body is the grill itself. The same logic harvests and injects. Only the sender checks: newest of each, still intact, nothing stale. Agents are never told to verify.
6. **Each agent kind declares which inputs it takes** (for the dispatch design, later). One small file per agent kind, owned by its component, naming the event types it consumes. For example:
   - build: context, grills, spec;
   - test: spec, test plan, build result;
   - hot internal review: context, grills, spec, diff;
   - cold internal review: spec, diff (deliberately without context and grills);
   - foreign review: diff (and perhaps spec).
   Dispatch reads the declaration, harvests the newest event of each type, and shows what's missing as "none" on the plan. Dispatch stays generic; a new agent kind is one file.
7. **Kept from earlier rounds:**
   - `context-add.sh` refuses paths inside the effort's own folder;
   - every ended grill goes to the agent, oldest first, with main's exceptions shown on the plan;
   - one freshness check at the send covers every pinned input;
   - "only senders cut" goes from the prose and the spec.

## The owner's open question: step candidates and flows

The owner wants to keep your `step.json` idea: each flow-sized skill declares itself as a step candidate. Main could then propose a dynamic flow from the candidates and the situation, for example: discovery, build the context, grill, specify.

Why it may fit better now than when you deferred it: every context-phase step ends in a fact on disk.
- Build the context: `context.cut`.
- Grill: `grill.ended`.
- Specify: `spec.approved`.
- Discovery: the open one. It writes no event; its end would be the human's confirmation, a criterion. Or discovery has no step of its own and is part of building the context, ended by `context.cut`.

So a context flow main offers would have every step checked by a script, never claimed. Nobody is nudged into one; main offers it when the situation calls for it.

## What the owner asks you

1. Do you confirm decisions 1 to 7? In particular decision 4 (spec approval not requiring a cut), against your last recommendation, and decision 3 (no card scripts).
2. The step candidates: now, or still with dispatch? If now, does the design hold?
   - `do`, `uses`, `done_when`, `flows` (a label only), `fits`, with no `optional` and no order, a list per file;
   - `flow-candidates.sh` with the check that each event has one rule;
   - no hook nudge.
   And how is discovery's step ended?
3. Anything in the whole that is inconsistent.
