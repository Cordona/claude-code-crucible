# Effort events: preview for approval

Rule: a field exists only if a script reads it. Each field below names its reader.

**Where they live:** `~/.crucible/efforts/<id>/events/<seq>-<type>.json`. The seq and the type are in the file name, so the order and the type are known without opening the file.

## The envelope (kept as today)

Every event carries today's envelope, written by `event-write.sh`:

| Field | Read by today | Why |
|---|---|---|
| `type` | every reader | The newest effort type is the state |
| `seq` | seats, review, dispatch, worktree push, the flow id | Order, and how events point at each other |
| `at` | list and status | When it happened |
| `by` | dispatch's provenance check, metrics | Which script wrote the fact, so its ownership is certain; metrics skip their own events |
| `claude_session_id` | metrics | Which session it happened in |
| `iteration` | seats | Optional: the seat iteration, stamped only by seat events |

## The three bodies

```json
{ "type": "effort.opened", "seq": 1, "at": "2026-11-21T10:02:11Z", "by": "effort-start.sh",
  "claude_session_id": "3b15192d-0617-427a-be22-290da7f067db", "body": { "name": "notes-search" } }
```

```json
{ "type": "effort.closed", "seq": 7, "at": "2026-11-23T16:40:00Z", "by": "effort-close.sh",
  "claude_session_id": "3b15192d-0617-427a-be22-290da7f067db", "body": { "outcome": "done", "words": "Shipped, nothing left" } }
```

```json
{ "type": "effort.reopened", "seq": 8, "at": "2026-11-25T09:15:30Z", "by": "effort-reopen.sh",
  "claude_session_id": "9c1e0a77-1b2c-4d5e-8f90-112233445566", "body": {} }
```

| Body field | Read by | Why |
|---|---|---|
| `name` | `effort-list.sh`, `effort-status.sh` | The name the human recognises |
| `outcome` | `effort-list.sh`, `effort-status.sh` | Done or dropped |
| `words` | `effort-status.sh` | Why it was closed, in the human's words: traceability and audit |

## Approved (owner, 2026-11-21)

The envelope stays as today. The bodies are `name` on open, `outcome` and `words` on close, and empty on reopen.

**Update 2026-11-21:** paused added (`effort.paused`, body `words`), reopened renamed to `effort.resumed` (from paused or closed, body `words`), and close is allowed from open or paused.
