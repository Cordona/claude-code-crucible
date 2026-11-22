# Spec: crucible-spec

A spec is the human-approved contract for an effort's work: the what and the why, never the how. Every agent works from it, and it is as small as the work. This component holds the how of drafting one with the human, and the one script that records an approval.

The spec is independent of the context and the grill. It is written from them where they exist, and is bound to no context version. Whoever sends agents reads the newest `spec.approved` and follows its path.

**Home:** `new-rewrite/framework/core/main-thread/crucible-spec/`

## The pieces

| Piece | Job |
|---|---|
| `SKILL.md` | The how: the five sections (Goal, Done when, Scope, Constraints, Open points), one short example, drafting with the human from the context and grills where they exist, when to revise |
| `scripts/spec-approve.sh --effort FOLDER --draft FILE` | Seals a draft the human accepted and records it as the effort's spec |
| `events/spec.approved.jq` | The rule for `spec.approved`: its shape, and that one yes approves once |

## Approving a draft

Drafts live in the effort's `spec/` folder. Each revision is a new file and needs a new approval; the newest `spec.approved` is the spec.

The draft itself is the card. Main asks at a recorded gate whose record is `spec-approval` and whose subject is the draft's sha256; the human accepts by picking the option named as yes.

`spec-approve.sh` then:

1. Asks `crucible-effort/scripts/effort-state.sh` for the effort's state, and refuses unless it is open.
2. Checks the draft: a regular file, not a symlink, directly in the `spec/` folder of the effort named by `--effort`, non-empty text, at most 1048576 bytes. It takes the draft's sha256.
3. Asks `crucible-gate/scripts/gate-answer.sh` for the human's newest answer on `spec-approval` and that sha256. A later no cancels an earlier yes.
4. Checks that this yes did not already approve a draft.
5. Makes the draft read-only (mode 444) where it is.
6. Writes `spec.approved {sha256, answer, path}` last, and prints the event's path.

It copies nothing and requires no context: the facts may have lived in the conversation. A failed event write leaves a read-only, unapproved draft, which is harmless; a rerun approves it.

| Exit | Meaning |
|---|---|
| 0 | Approved |
| 1 | The human has not accepted this draft |
| 2 | Refused: the yes was already used, the effort is not open, the draft is not a regular text file, is not in this effort's `spec/` folder or is over 1 MB, or a bad argument |
| 6 | The events lock stayed held: rerun |

## The event

```json
{ "sha256": "9f2c…", "answer": 14, "path": "/…/<effort>/spec/prune-v2.md" }
```

| Field | Read by | Why |
|---|---|---|
| `sha256` | Whoever sends agents, to check the file still gives it | Which draft was approved |
| `answer` | `spec-approve.sh` and the rule, for used once | The proof: the seq of the human's `gate.answered` |
| `path` | Whoever sends agents, to find the spec | Where the approved, read-only file is |

The rule holds only the shape (no other fields, `sha256` as 64 lowercase hex digits, `path` absolute and ending `/spec/<name>`, `answer` a number) and used once. It does not re-read the answer; that is `gate-answer.sh`'s job.

## Decided, and why

- **The draft is the card:** the human sees exactly what the sha256 proves.
- **Sealed in place:** the approved file stays in the effort's `spec/` folder, read-only, so it is durable and the event can point at it.
- **No spec-status script:** the newest `spec.approved` and the flow's track already say where the spec stands.
- **Used once:** going back to an earlier draft after a later one was approved needs a fresh yes.
- **Revise only when the goal, done-when or scope changes:** a small change does not need the human's gate again.

## Known limits

- A long draft is relayed as the card, so main may not relay it exactly, and every revision is printed in full. The fallback, not built: a script-rendered card with the path, size and headings.
- Agents still running when a spec is revised need the new spec's path; that belongs to the dispatch side.
