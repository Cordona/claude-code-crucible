# Spec: gate answer events (in crucible-gate)

**Purpose:** when a piece must act only on the human's decision, such as approving a spec, a dispatch or a commit, it needs proof that the human actually decided. Main's retelling isn't proof. The proof is the human's own answer, taken from the AskUserQuestion result by a hook and written once as an event. Only gates that ask for it leave one; every other gate leaves nothing.

## 1. How a gate asks to be recorded

Every gate already starts with `show-card.sh`. A recorded gate adds three options to that call:

```
sh show-card.sh --record spec-approval --effort <folder> --subject <sha256 of the draft> --accept "Approve the spec (Recommended)" <card file>
```

| Option | Meaning |
|---|---|
| `--record NAME` | What the decision is, a short kebab name: `spec-approval`, `effort-start`, `dispatch` |
| `--effort FOLDER` | The effort whose log receives the answer |
| `--subject TEXT` | Optional. What exactly was decided on, such as the draft's sha256 or the plan's fingerprint, so a piece can tie the answer to that exact thing |
| `--accept LABEL` | The option label that means yes. It's declared before the human answers, and it must be one of the question's options, which the question hook checks |

**Why `--accept`:** the questions are dynamic, so no script can tell from a label alone whether "Approve the spec (Recommended)" means yes. Main declares which option means yes before the human answers, and the human sees that exact option. `accepted` is true only when the human picked that very option. A typed answer, through "Other", is never acceptance.

## 2. The event: `gate.answered`

```json
{ "record": "spec-approval", "subject": "9f2c…", "question": "Approve this spec?", "accept": "Approve the spec (Recommended)", "answer": "Approve the spec (Recommended)", "accepted": true }
```

| Field | Read by | Why |
|---|---|---|
| `record` | the deciding piece (`spec-approve.sh`, `flow-agree.sh`, later dispatch and commit) | Which decision it was |
| `subject` | the deciding piece | That the answer is for this exact draft or plan |
| `accepted` | the deciding piece | Yes or no, worked out by the hook, never claimed by main |
| `question`, `accept`, `answer` | no script; kept on purpose | They are the content of the proof: `accepted: true` with no record of what was asked and what counted as yes proves nothing to the human who later asks why |
| envelope `by` | the deciding piece | It accepts only an answer the hook wrote |

There's one event type, so one rule file, `crucible-gate/events/gate.answered.jq`. A piece never reads the answers itself: it asks `scripts/gate-answer.sh --effort --record --subject`, the one home of the reading rule. The newest answer counts, so a later no cancels an earlier yes.

## 3. The pieces

| Piece | Change |
|---|---|
| `scripts/show-card.sh` | Takes `--record`, `--effort`, `--subject` and `--accept`, and keeps them in the owed record |
| `hooks/pre-tool-use/hold-question-until-card-shown.sh` | When it lets a recorded card's question go out, it refuses if `--accept` isn't one of the options, and leaves a hand-off under the question's `tool_use_id` |
| `hooks/post-tool-use/record-gate-answer.sh` (new) | On PostToolUse for AskUserQuestion, it reads the hand-off and the tool result's answer, works out `accepted`, and writes `gate.answered` through `event-write.sh`. It never blocks; a fault is shown on stderr |
| `events/gate.answered.jq` (new) | The body's shape |

## 4. Decided (Fable's review, 2026-11-21)

- **Only recorded gates write.** The answer comes from the tool result, never from main. `accepted` is computed by the hook, and a typed answer is never acceptance.
- **A recorded gate is one single-select question.** The question hook refuses anything else.
- **A piece that acts on an exact thing** (a spec draft, a plan, a commit) requires a `subject` and refuses an answer without one. There's no age limit in the gate; an age rule, if ever wanted, is the piece's own.
- **Whether an acceptance can be used twice** is the deciding piece's rule, decided when dispatch and commit are built.
- **Not covered:** decisions before or outside an effort, such as `effort-start` or a commit with no effort. They're decided when they're wired. The hand-off stays general enough for an answer kept per session later.
- **The known limit:** `accepted` is one yes/no. A gate whose answer is a choice between several actions (which findings to fix, a review's scope) needs a declared token per acting option, added beside `accepted` when the first such piece arrives.
- **Later:** the dashboard answer path, when a real case shows up.
- **Decided (owner + Fable):** `flow-agree.sh` requires a recorded answer, record `flow-agree` with the flow file's sha256 as its subject, and its card is rendered from the flow file. See `dynamic-flow.md`.

- **Deliberate:** a recorded gate's answer is written even while the effort is paused. The answer is a fact, unlike flow and context writes, which happen only while the effort is open.
