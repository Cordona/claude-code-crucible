# Spec: crucible-spec

A spec is the human-approved contract for an effort's work: the what and the why, never the how. Every send of agents has one, as small as the work; the context cut refuses without it. This skill holds the how of drafting one, and the one piece that records an approval.

**Home:** `new-rewrite/framework/core/main-thread/crucible-spec/`

## 1. The piece: `scripts/spec-approve.sh --effort FOLDER --draft FILE`

1. Takes the draft's sha256.
2. Asks `crucible-gate/scripts/gate-answer.sh --effort FOLDER --record spec-approval --subject <sha>`. With no acceptance, it refuses.
3. Copies the draft into the context's draft docs folder as `spec.md`, replacing an earlier one. It gets the folder from `crucible-context/scripts/context-docs.sh`.
4. Writes `spec.approved` last, the outcome event a flow step names in its `done_when`. Copying first means a failed copy leaves the answer unused, so a rerun works.

| Rule | Why |
|---|---|
| A refusal without an accepted answer for this exact draft | The approval is a fact, not main's claim |
| A refusal when that answer was already used by an earlier `spec.approved` | One yes approves one draft once |
| A refusal unless the effort is open | Asked through `context-docs.sh` |
| A refusal for a draft that isn't a regular text file, or is over 1 MB | It goes into every agent's context |

**The script takes a draft from any path,** because the sha binds the approval to the content. By convention, stated in the how, drafts live in the effort's folder outside its context, at `<effort>/spec/`. A scratchpad draft can vanish, and a draft in the docs folder would be cut unapproved.

## 1b. The change to the context (owner's go needed: it changes a built script)

The cut refuses unless `spec.md` is the approved one: its sha256 must equal the newest `spec.approved`'s `sha256`. The check sits in the shared body builder, so `context-fingerprint.sh` refuses too, and an unapproved spec never reaches a plan or an agent. Today the cut only checks that a `spec.md` exists, so a draft saved there as `spec.md` would be sealed and sent unapproved.

## 2. The event: `spec.approved`

```json
{ "sha256": "9f2c…", "answer": 14 }
```

| Field | Read by | Why |
|---|---|---|
| `sha256` | the context cut (it must equal `spec.md`'s), a flow step's `match` if wanted | Which draft was approved |
| `answer` | `spec-approve.sh` and the rule (used once) | The proof |

Its rule, `events/spec.approved.jq`, holds only what is the piece's own: the shape, and that `answer` isn't used by an earlier `spec.approved`. It doesn't re-read the answer; that's `gate-answer.sh`'s job.

**There's no path field,** because the next cut moves the docs folder. Where the spec is belongs to the context to say.

## 3. How the approval is asked

The card is the draft itself: `show-card.sh --record spec-approval --effort F --subject <sha> --accept "<the yes label>" <draft file>`. The human then sees exactly what the sha proves, the same reason the flow's card is rendered from its file. Then one single-select question.

## 4. The how: `SKILL.md`, about 200 words, written after the piece

It covers judgment only:
- **What a spec is:** the five sections of today's `standard-spec`, each holding only its own substance:
  - Goal;
  - Done when;
  - Scope (in and out);
  - Constraints (and what needs the human's OK first);
  - Open points (at approval, none is left open, or the human leaves them to the agents).
- **As small as the work.** A one-line fix gets a few lines.
- **Never the how,** never a tool choice unless the human requires one, and never the project's own rules.
- **Drafted with the human.** Each revision is a new file. It's approved at a recorded gate, whose card is the draft.
- **Revise only when the goal, done-when or scope changes;** never for a small change.
- One short example.

## 5. Decided (Fable's review, 2026-11-21)

- **The draft is the card,** for now. The live run watches how often a longer draft isn't relayed exactly, and the cost of printing every revision. The fallback, not built: a script-rendered card with the path, size and headings, never a summary main writes.
- **No `spec-status.sh`:** the cut, the flow's track and the context's status cover it.
- **`sha256` stays:** the cut reads it.
- **Used once stays:** going back to an earlier draft after a later one was approved needs a fresh yes.
- **For the dispatch side:** every agent still running gets a revised spec's path.
- **The how keeps two slip-born rules:** each revision is a new file, and revise only when the goal, done-when or scope changes. There is nothing about typed answers, failed gates or "what next".
