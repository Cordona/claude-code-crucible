# The grill: what it is today, and a strategy

## 1. What a grill is

A grill is an interview that helps the human decide what they want when they don't yet know what they don't know. Main asks a few short questions at a time, each with a recommended answer and why. The human decides; main never decides for them. It ends when both share one understanding. Each settled answer is a decision the worker agents read through the context.

## 2. What `procedure-grill` does today

There are about 2,500 words of prose: `SKILL.md` has 2,028, `offer.md` 341, `resume.md` 129, and there's one fixed question. On the script side there's `grill.sh` (7,381 words, seven commands), `grill-validator.jq` (1,241) and three card views.

**The grill file** is a mutable draft, `<effort>/drafts/main-thread/grill-<n>.json`, written only by `grill.sh`:
- `{claude_session_id, number, topic, questions[]}`;
- each question is `{id q1.., claude_session_id, text, parent, round, recommendation {text, reason}, status open|settled|dropped|deferred, answers[]}`;
- each answer is a revision: `{revision, at, claude_session_id, change_reason, text}`.

The texts have caps (a question is at most 120 characters), and a round holds at most 3 questions.

**The commands:**

| Command | Job |
|---|---|
| `new` | Creates the draft, with the next grill number in the effort |
| `add` | Appends open questions, each with its recommendation, reason and optional parent |
| `ask` | Prints a round card (1–3 open questions) through the old card relay, and numbers the round |
| `answer` | Records answers. Changing a settled answer needs a reason, keeps the earlier revisions, and sends its settled children back to open |
| `status` | Drops, defers or reopens a question, with a reason |
| `end` | Copies the grill into the context's docs folder as `grill-<n>.json`, writes a `grill.ended` event whose body is the whole grill, and removes the draft |
| `list` | Lists the effort's grills, open and ended, with their open count |

**What the prose holds:**
- When to offer a grill, through an offer gate with a fixed question.
- Joining or starting an effort.
- Reading the context first, so no question asks a fact.
- The round rules:
  - open questions first;
  - no dependent questions in one round;
  - a settled question is never asked again;
  - only a direct answer is recorded, and a bare "yes" accepts the recommendation.
- Explaining when asked.
- Change, drop and defer.
- Ending, with a hand-back into `procedure-context`'s fixed steps.
- Resume.
- No parallel `grill.sh` calls, because it has no lock.

**Who else reads it:** the context's docs rule allows `grill-<N>.json`. Resume and the agents read the grill through the context.

## 3. Where it breaks the constitution

- **One script with seven jobs** (value 17).
- **A fixed hand-back into another skill's step numbers** ("`procedure-context` step 5, then its step 7"), and step chains into `procedure-effort`'s steps 3–4 (values 5, 14, 15).
- **A fixed offer question and renderer.** The generic gate covers these now (value 7).
- **Exit-code trees, install-fault lines, and Never/Always lists** (value 6).
- **The same grill stored twice:** as a docs copy and as the `grill.ended` event body (value 11).
- **No lock,** so the invariant "never parallel calls" lives in prose (value 3).

## 4. Strategy

### The how: `crucible-grill/SKILL.md`, about 200 words

It covers only the judgment:
- what a grill is for;
- offer one when the goal looks open, at a gate;
- read what's known first, so no question asks a fact;
- small rounds of independent questions, each with a recommendation and why;
- never decide for the human;
- record only direct answers, and give a reason when an answer changes;
- drop or defer what no longer fits;
- end when the understanding is shared.

It doesn't hold:
- effort or context steps (the agreed flow and those skills cover them);
- offer machinery (the generic gate);
- resume steps (`grill-list.sh` shows the open grill);
- exit codes.

### The pieces: `crucible-grill/scripts/`

Each is small, does one job and is callable alone:

| Script | Job |
|---|---|
| `grill-new.sh --effort --topic` | Opens a grill draft with the next number |
| `grill-add.sh --grill --question --recommendation --reason [--parent]` | Adds open questions, and prints their ids |
| `grill-answer.sh --grill --id --text [--change-reason]` | Records answers. A change needs a reason, and sends the settled children back to open |
| `grill-status.sh --grill --id --to dropped\|deferred\|open --reason` | Drops, defers or reopens a question |
| `grill-show.sh --grill [--open]` | Prints the grill, or only its open questions, for main to build the next round from |
| `grill-end.sh --grill` | Writes the `grill.ended` event, adds it to the context as a reference, and removes the draft |
| `grill-list.sh --effort` | Lists the effort's grills: open or ended, the open count, the topic |
| `lib/grill-shape.jq` | The grill's shape, in one home. Every writer checks it, and the event rule includes it |
| `events/grill.ended.jq` | The ended grill's rule, which includes the shape |

A lock in `lib/` replaces the "never parallel calls" rule.

### The changes worth judging

1. **No round card and no `ask` command.** Main asks the round itself, in plain text built from `grill-show.sh --open`, or as one AskUserQuestion of up to 3 questions. That second form fits the gate's rules: a recommended option first, with why, and "Other" for the human's own words. `round` is dropped from the shape unless something reads it.
2. **No docs copy.** `grill-end.sh` writes the `grill.ended` event, which is sealed, then calls `crucible-context`'s public `context-add.sh --path <that event> --why "grill: <topic>"`. The agents read it through the context. That's one copy, and `grill-<N>.json` leaves the docs rule.
3. **The draft stays a mutable file until the end,** like the context draft. Only the end is an event. Each answer keeps its revisions inside the draft.
4. **The draft lives at `<effort>/grills/<n>.json`,** one home, instead of `drafts/main-thread/`.
5. **The open-effort check** uses `effort-state.sh`, as the context does.
6. **The lock:** the context, `event-write.sh` and now the grill each need one. It's the third use, so a shared lock piece may be due (value 11: abstract after real repetition).

## 5. Questions for the reviewer and the owner

- Rounds as plain text, or as AskUserQuestion with up to 3 questions?
- The event as the single copy, referenced from the context?
- A shared lock piece now, at the third use, or keep a copy per component?

## 6. After Fable's review (2026-11-21)

All three rulings and all nine findings are accepted. The changes:

- **Rounds:**
  - The pieces don't care how a round is asked. Main picks per round: plain text for open answers, AskUserQuestion for a real choice between a few options.
  - The cap of 3 becomes "a few" in the how.
  - `round`, the round card and `ask` go.
- **`grill-end.sh`** only writes the `grill.ended` event, removes the draft and prints the event's path. Main adds that path to the context with `context-add.sh`, as a step of the agreed flow. The grill doesn't call the context.
- **`grill-status.sh` is renamed `grill-mark.sh`,** so `-status` means read-only across the framework.
- **The text caps go,** except "one line" and a total size bound on the event. The how shows one good example question.
- **No shared lock yet.** This is a third copy of the lock, the refuse helper and the open-effort check. After the grill is built, the owner gets one decision on a shared home for all three.
- **Context clean-up:** `grill-<N>.json` leaves the docs rule, and `context-docs.sh --help` stops listing who writes into it.
- **The how keeps three slip-born lines:**
  - a hedge, a question back or a "yes, but" stays open, and a bare "yes" accepts the recommendation;
  - no secret goes into a question or an answer;
  - a wrong question is dropped and re-added with the old one as its parent.

  It adds one positive example of a round. The rule that an ended grill can still hold open or deferred questions, so readers check each question's status, goes there too.
- **For the dispatch side, later:** between grills, the later `grill.ended` (by seq) wins.

### The grill's shape, for approval

The draft and the `grill.ended` body share one shape:

```json
{
  "number": 1,
  "topic": "How the prune command should behave",
  "questions": [
    {
      "id": "q1",
      "text": "Who runs the prune: a person or a cron job?",
      "recommendation": { "text": "A cron job", "reason": "It runs nightly with no one around" },
      "status": "settled",
      "answers": [ { "text": "A cron job" } ]
    },
    {
      "id": "q2",
      "parent": "q1",
      "text": "Should it email on failure?",
      "recommendation": { "text": "Yes", "reason": "No one watches a cron job" },
      "status": "settled",
      "answers": [ { "text": "No" }, { "text": "Yes", "change_reason": "Ops wants to know" } ]
    }
  ]
}
```

| Field | Read by | Why |
|---|---|---|
| `number` | `grill-list.sh`, the file name | Tells the effort's grills apart |
| `topic` | `grill-list.sh`, the context why main writes | What the grill was about |
| `questions[].id` | `grill-answer.sh`, `grill-mark.sh`, `grill-show.sh`, `parent`, citations | Names a question |
| `questions[].text` | `grill-show.sh`, agents | The question |
| `questions[].parent` | `grill-answer.sh` (reopens the children of a changed answer), agents | Where a question came from |
| `questions[].recommendation.text`, `.reason` | `grill-show.sh` (main builds the round from it), agents | What was recommended, and why |
| `questions[].status` | `grill-show.sh --open`, `grill-list.sh`, agents | open, settled, dropped or deferred |
| `questions[].answers[].text` | `grill-show.sh`, agents | The answer. The last one is current; the earlier ones are kept |
| `questions[].answers[].change_reason` | agents, audit | Why an answer changed |

**Dropped from today's shape** because nothing reads them: `claude_session_id` at the top, on each question and on each answer (the event's envelope has it); `round`; `revision`, which is the answer's place in the list; and `at` on each answer.

**For the owner:**
1. Approve the shape?
2. F5: today "grill me" counts as the effort yes. Should the human's own ask still open the effort with no separate offer?
3. ~~Narrow the card rule?~~ Decided (owner, Fable approved with changes): grill rounds are mini gates, a small card then one AskUserQuestion, and the rule stays. The cost is one human step and one extra main step.

### Rounds as mini gates (owner's idea; Fable approved with changes, 2026-11-21)

- **C1:** the round card is small and says only what changed: what the last answers settled, what this round is about, and the counts. It never lists every settled answer and never restates the questions.
- **C2:** the gate is the default, not the only way. A question with no real options (a name, a fact only the human holds) is asked in a plain sentence. Main never invents options to fit the dialog.
- **C3:** explaining stays conversation. Asking again needs a new card, kept to one line.
- **C4:** a live grill of four or more rounds before the how is settled. Watch:
  - whether the dialog opens with no human action between the card and the question;
  - how often main fails to relay the card;
  - whether the owner still reads, or clicks the recommendation through;
  - whether main invents options.

  The owner has deferred live runs until the context part is complete.
- **To watch:** a forced recommendation on pure-preference questions. If a live run shows it, allow a question to carry none.

**Approved (owner, 2026-11-21):** the shape above, and "grill me" as the effort yes, with no separate offer.
