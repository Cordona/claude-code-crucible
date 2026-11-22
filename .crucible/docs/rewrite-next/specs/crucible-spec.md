# Spec: crucible-spec

A spec is the human-approved contract for an effort's work: the what and the why, never the how. Every agent works from it, and it is as small as the work. This component holds the how of drafting one with the human, and the one script that records an approval.

**Home:** `new-rewrite/framework/core/main-thread/crucible-spec/`

## The pieces

| Piece | Job |
|---|---|
| `SKILL.md` | The how: the five sections (Goal, Done when, Scope, Constraints, Open points), one short example, drafting with the human, when to revise |
| `scripts/spec-approve.sh --effort FOLDER --draft FILE` | Records a draft the human accepted as the effort's spec |
| `events/spec.approved.jq` | The rule for `spec.approved`: its shape, and that one yes approves once |

## Approving a draft

Drafts live in the effort's folder, at `<effort>/spec/`, by convention stated in the how. Each revision is a new file. The script takes a draft from any path, because the sha256 binds the approval to the content.

The draft itself is the card. Main asks at a recorded gate whose record is `spec-approval` and whose subject is the draft's sha256; the human accepts by picking the option named as yes.

`spec-approve.sh` then:

1. Checks the draft: a regular file, not a symlink, non-empty text, at most 1048576 bytes. It takes the draft's sha256.
2. Asks `crucible-gate/scripts/gate-answer.sh` for the human's newest answer on `spec-approval` and that sha256. A later no cancels an earlier yes.
3. Checks that this yes did not already approve a draft.
4. Gets the context's draft docs folder from `crucible-context/scripts/context-docs.sh`, which refuses unless the effort is open, and copies the draft there as `spec.md` through a temp file and a rename, replacing an earlier one.
5. Writes `spec.approved {sha256, answer}` last, and prints the event's path.

Writing the event last means a failed copy leaves the yes unused, so a rerun works.

| Exit | Meaning |
|---|---|
| 0 | Approved |
| 1 | The human has not accepted this draft |
| 2 | Refused: the yes was already used, the effort is not open, the draft is not a regular text file or is over 1 MB, or a bad argument |
| 6 | The events lock stayed held: rerun |

## The event

```json
{ "sha256": "9f2c…", "answer": 14 }
```

| Field | Read by | Why |
|---|---|---|
| `sha256` | The context's cut: `spec.md`'s sha256 must equal the newest `spec.approved`'s, or it refuses `NOT-APPROVED` | Which draft was approved |
| `answer` | `spec-approve.sh` and the rule, for used once | The proof: the seq of the human's `gate.answered` |

The rule holds only the shape (no other fields, `sha256` as 64 lowercase hex digits, `answer` a number) and used once. It does not re-read the answer; that is `gate-answer.sh`'s job.

There is no path field, because the cut moves the docs folder. Where the spec is belongs to the context to say.

## The one accepted pair

The context reads `spec.approved`, and `spec-approve.sh` writes `spec.md` into the context's folder through its public `context-docs.sh`. That couples the two components in both directions. It is deliberate: the cut is the one place an unapproved spec can be stopped before it reaches a plan or an agent. It is known as the one such pair, not a pattern to copy.

## Decided, and why

- **The draft is the card:** the human sees exactly what the sha256 proves.
- **No spec-status script:** the cut, the flow's track and the context's status already say where the spec stands.
- **Used once:** going back to an earlier draft after a later one was approved needs a fresh yes.
- **Revise only when the goal, done-when or scope changes:** a small change does not need the human's gate again.
- **Drafts outside the docs folder:** a scratchpad draft can vanish, and a draft in the docs folder would be cut unapproved.

## Known limits

- A long draft is relayed as the card, so main may not relay it exactly, and every revision is printed in full. The fallback, not built: a script-rendered card with the path, size and headings.
- Agents still running when a spec is revised need the new spec's path; that belongs to the dispatch side.
