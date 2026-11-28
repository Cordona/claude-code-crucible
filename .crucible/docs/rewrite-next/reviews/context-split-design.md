# Design: the context, the grill and the spec as three facts (2026-11-22)

Built from the decisions in `context-spec-grill-decisions.md`, as Fable confirmed them, with its additions. The owner's go: build once Fable approves this design; verify the scripts by execution; then Fable reviews the result against the constitution and the Opus 5.5 prompting practices; then a live replay with the Validator.

## 1. Context (`crucible-context`)

**What it holds:** outside paths and links, each with a why, plus the draft docs: notes, ticket copies and patches. Never the spec, never a grill.

| Piece | Change |
|---|---|
| `context-cut.sh --effort FOLDER` | Drops `--expect`. It works out the would-be version's fingerprint and asks `gate-answer.sh --record context-done --subject <fingerprint>`. With the human's yes it cuts, as today: docs to `context/v<N>/` read-only, `context.cut` written, pending entries cleared. Without it, exit 1 (NOT-CONFIRMED), the same exit `spec-approve.sh` uses for "not accepted". If the draft changed since the yes, the fingerprint differs, so it is the same refusal and the human is asked again. With nothing new since the last cut it prints the latest version and writes nothing. No "used once": cutting an unchanged context twice already writes nothing. |
| `context-fingerprint.sh` | Same output (`FINGERPRINT`, `VERSION`). Its job is now the gate's subject. The spec checks go. An empty context gives the fingerprint of an empty first version. |
| `lib/body.sh` | The NO-SPEC and NOT-APPROVED checks go, as does carrying `spec` forward. CONTEXT-NONE goes: with no version yet and nothing pending, the would-be version is v1 with `paths: []`. |
| `events/context.cut.jq` | The body is `{version, paths, links?}`. `spec` and its NO-SPEC check go. |
| `context-verify.sh` | Its NO-SPEC check goes. It still checks place, size, shape, docs digests and that this is the newest version. |
| The docs rule (`lib/body.sh`) | `spec.md` is refused as a docs name ("the spec lives in the effort's spec/ folder"), so a stray copy is never taken for the spec. `<name>.md` and `diff-<sha>.patch` stay. |
| `context-add.sh` | Refuses any `--path` inside the effort's own folder, not only inside `context/`: "the effort's own facts reach agents through the sender, never as a reference". |
| `context-status.sh`, `context-drop.sh`, `context-docs.sh`, `context-path-check.sh` | Unchanged. |

## 2. Spec (`crucible-spec`)

| Piece | Change |
|---|---|
| `spec-approve.sh --effort FOLDER --draft FILE` | The draft must be a file in `<effort>/spec/`, so it is durable; elsewhere is refused. On the human's accepted, unused yes it makes the draft read-only (mode 444) where it is, and writes `spec.approved {sha256, answer, path}`. It no longer calls `context-docs.sh` or copies anything. Requires no `context.cut`: the facts may have lived in the conversation. A revision is a new file and a new approval; the newest `spec.approved` is the spec. |
| `events/spec.approved.jq` | Adds `path`: an absolute path ending in `/spec/<name>`. It keeps sha256 and used-once. |

## 3. Grill (`crucible-grill`)

No code change. `grill-end.sh --help` drops "to give it to the agents, add the event's path to the effort's context". The sender finds `grill.ended` itself.

## 4. Prose

- **`crucible-context/SKILL.md`:**
  - The context is the outside material gathered for the work.
  - It is cut when the human says it's done, at a recorded gate whose subject is the draft's fingerprint, and the draft's path goes on main's card. Read every entry yourself before asking.
  - A later change means another "done?" and another version.
  - The description changes to match.
- **`crucible-discovery/SKILL.md`:**
  - "Discovery is done when the human confirms…" becomes: where there is a context, that confirmation is the human's yes at its "done?" gate.
  - "Ask the human only what the material can't answer" is narrowed to facts; a choice goes to a gate.
- **`crucible-gate/SKILL.md`:** "a decision that matters" is sharpened. A question whose answer changes the outcome is a gate; several go in one dialog, up to four, behind one small card.
- **`crucible-spec/SKILL.md`:**
  - Drafts in the effort's `spec/` folder.
  - Written from the context and the grills where they exist.
  - The approved draft stays where it is, read-only.
  - No word about the context's docs.
- **`crucible-grill/SKILL.md`:** "add the event's path to the context" goes. "Never put a secret in a question or an answer: every agent reads the ended grill" stays.
- **`crucible-dynamic-flow/SKILL.md`:** its example becomes a context flow whose steps end in `context.cut`, `grill.ended` (optional, named only when the goal is open) and `spec.approved`. That is three event names in one prose file, accepted until the step catalogue replaces it with dispatch.
- **Not touched:** core `CLAUDE.md`, the effort skill, the domain skills.

## 5. Specs and HANDOFF

- **`crucible-context.md`, `crucible-spec.md`:** rewritten for the split. "The one accepted pair" goes; the context and the spec no longer know each other.
- **`crucible-grill.md`:** "how it reaches the agents" changes to: the sender reads `grill.ended`.
- **`crucible-dynamic-flow.md`:** the example note.
- **HANDOFF "Recorded, not built", for the dispatch design:**
  - The sender harvests the newest `context.cut`, every `grill.ended` (oldest first) and the newest `spec.approved`, and gives agents event paths.
  - Only the sender checks: newest of each, still intact, the spec file still giving its sha256.
  - It refuses when the context's draft holds uncut content, naming it. Only an empty draft with no cut shows as "none".
  - It shows work in progress (an open grill, a spec draft newer than the approved one) beside any "none".
  - One freshness check covers every pinned input.
  - Each agent kind declares the event types it takes.
  - "Plan inputs" are designed once, not as three special cases.
  - Whether the flow's agreement and the plan's approval are one gate or two.
  - The step catalogue (`step.json`) arrives with dispatch, with the shared "beside" helper first.
  - The Validator's stop point for a context-phase run: a `context.cut` (or none, by the human's choice) and a `spec.approved`.

## 6. Evidence

Runs from `/`, every path taken from stdout, nothing hidden.

- **context-run:**
  - Cutting is refused without the human's yes (exit 1).
  - With the yes for the current fingerprint, it cuts.
  - An entry added after the yes means refused, asked again, then cut.
  - An empty context, with nothing added, cuts as v1 with `paths: []`.
  - Cutting an unchanged context writes nothing.
  - `spec.md` in the docs is refused.
  - A path inside the effort folder is refused by `context-add`.
  - Verify still checks staleness and tampering.
- **spec-run:**
  - Approving with no context at all succeeds.
  - The approved draft is read-only and `spec.approved` names its path.
  - A draft outside `<effort>/spec/` is refused.
  - "Yes then no", "used once" and the revision cases are kept.
  - Nothing appears in the context's docs.
- **grill-run:** the hand-off-to-context case becomes "the grill's event exists and context-add refuses its path".
- **installed-run and tracker-run:** the cut through a recorded "done?" gate, and the spec approved without the context.
- **fixes-run, dynamic-flow-run, gate-answers-run, effort-run, events-run:** re-run, expected unchanged; any change explained.

## 7. What this design does not do

- Build dispatch, agent input files or the step catalogue.
- Change how a recorded gate works. `context-done` is a new record name only.
- Nudge anyone into a flow.

## 8. Decided in review (Fable, 2026-11-22): go, with these in

1. `spec-approve.sh` checks the open effort itself, through `effort-state.sh`, since it no longer calls `context-docs.sh`. The paused-effort refusal stays in the evidence.
2. The draft must be in the `spec/` folder of the effort named by `--effort`; a draft in another effort's `spec/` is refused.
3. Evidence to add:
   - context-cut after "yes, then no" on one fingerprint: refused;
   - context-cut after a typed answer: refused;
   - an empty context is cut only with a yes;
   - context-add refuses the effort's spec file and a `grill.ended` event by path;
   - spec-approve in a paused effort: refused;
   - each event the flow skill's example names has exactly one rule file.
4. `spec-approve.sh` makes the file read-only, then writes the event. A failed write leaves a read-only, unapproved draft; that is harmless, and a rerun works. The spec says so.
5. The flow's example has three plain steps; "optional" is not a node field. The sentence around it says a grill belongs only when the goal is open, and that a step with no event takes a criterion. The flow's own `done_when` stays a criterion.
