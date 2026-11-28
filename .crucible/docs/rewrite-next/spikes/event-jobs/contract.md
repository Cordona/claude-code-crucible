# Spike contract: events and script outputs

The shapes every lab script, fixture and expected output share. It holds the shapes only: the rules of what is owed come from `spec.md`, `../../reviews/job-model-fable.md` and `../../reviews/job-model-loop-fable.md`. Spike-only, like everything here.

## 1. Events

### 1.1 The envelope

An event is one file `events/<seq, 6 digits>-<type>.json`, written only by `lab/ev.sh`:

```json
{ "seq": 7, "type": "job.dispatched", "at": "2026-11-24T09:00:07Z", "session": "S1",
  "root": 1, "round": null, "job": null, "agent": null, "body": { } }
```

| Field | Meaning |
|---|---|
| `seq` | 1, 2, 3, … in the effort; also the event's id |
| `session` | the main session that was running when it was written |
| `root` | the seq of the event that started the chain: a `build.submitted` whose job had no root, a `range.imported`, an `external-review.received` or a `pr.review-requested`. A chain's first event has `root` equal to its own seq. `null` only for events outside any chain (`job.dispatched` of a first build) |
| `round` | the seq of the `round.made` the event belongs to, or `null` |
| `job` | the seq of the `job.dispatched` the event belongs to, or `null`. A `job.dispatched` has `job: null`, because its own seq is the job |
| `agent` | the agent id, on `job.assigned` and on everything the agent's job writes after it |

`ev.sh` refuses an event whose `root`, `round` or `job` names a seq that doesn't exist, or one of the wrong type.

### 1.2 The types

| Type | Written by | Body |
|---|---|---|
| `job.dispatched` | `job-dispatch.sh`, `round.sh` | `kind`, `target` (seq), `tree` (path or null), `report` (the path its agent writes its report to: `<effort>/reports/<job seq>.json`), `agent_type`, `delivery` (`cold` or `hot`), `hot_agent` (id or null), `slot` (round slot or null), `replaces` (job seq or null), `approval` (seq of the event that covers this dispatch: a `gate.answered` or a `fix.chosen`; never null), `payload` (by kind, 1.3), `act` (from the fixture, opaque) |
| `job.assigned` | `post-agent.sh`, `post-send.sh` | `name` (such as `review-shell-af6bac`), `tool_use_id` |
| `job.ended` | `agent-stop.sh`, `job-end.sh`, `orphans.sh` | `reason`: `gave-up`, `cancelled` or `died` |
| `build.submitted` | `agent-stop.sh` | `commit` (or null when a fix declined every finding), `files` (the files the commit changed, `[]` with no commit), `report` (path), `answers` (for a fix: `{id: done \| declined}`), `declines` (`{id: reason}`) |
| `test.submitted` | `agent-stop.sh` | `commit`, `files`, `report`, `answers`, `declines` |
| `plan.submitted` | `agent-stop.sh` | `draft` (path), `answers` (for a rework: `{challenge key: applied \| cannot}`) |
| `review.submitted` | `agent-stop.sh` | `report` (path), `findings` (new ones: `[{kind, file, severity, realism, title, thread}]`, `thread` only on an external review, else absent), `answers` (earlier IDs: `{id: fixed \| open \| withdrawn \| insisted}`), `rulings` (arbiter only: `{id: fix \| drop}`), `challenges` (challenger only: `[{key, target, title}]`, `key` given by the stop check, `C-<n>` numbered across the effort), `threads` (external only: `{thread: valid \| rejected}`) |
| `round.made` | `round.sh` | `kind` (`code`, `external`, `challenge`), `targets` (seqs it covers), `base`, `head`, `slots` (`[{slot, kind, agent_type, cover}]`), `loop` (seq of the `fix.chosen` it runs under, or null) |
| `review.merged` | `merge.sh` | `findings` (`[{id, kind, file, severity, realism, status}]`, status `open`, `fixed`, `withdrawn`, `insisted`, `ruled-fix`, `ruled-drop`, `skipped`), `verdict` (`pass` or `changes`), `targets` (the IDs a next fix would take, by the harvest rule, or `[]`), `gaps` (slots that ended with no report) |
| `gate.answered` | `gate.sh` | `step` (`review`, `test-plan`, `build`, `test`, …), `answer` (the human's words). The only approval of a gated dispatch |
| `fix.chosen` | `choose.sh` | `merge` (seq), `query`, `ids`, `cap` |
| `fix.none` | `choose.sh` | `merge` (seq): the human chose to fix nothing, which ends the choice |
| `plan.approved` | `choose.sh` | `plan` (seq of the `plan.submitted`): ends the plan gate |
| `waiver` | `choose.sh` | `ids`, `reason` |
| `loop.stopped` | `choose.sh` | `reason` |
| `loop.ended` | `loop-end.sh` | `reason`: `clean`, `cap`, `deadlock`, `replacement-failed`, `refused`, `stopped` |
| `fact.answered` | `choose.sh` | `fact` (its key, 2.1), `answer` (`no`) |
| `range.imported` | `import.sh` | `base`, `head`, `tree` |
| `external-review.received` | `remote.sh` | `pr`, `head`, `threads` (`[{thread, file or null, text}]`) |
| `pr.review-requested` | `remote.sh` | `pr`, `base`, `head`, `tree` |
| `pr.head-moved` | `remote.sh` | `pr`, `old_head`, `head`, `replies` (`{finding id: text}`) |
| `pr.posted` | `remote.sh` | `items` (`[{thread or finding id, kind: reply \| comment}]`) |
| `root.closed` | `choose.sh` | `reason` |

### 1.3 Payload by job kind

| Kind | Payload |
|---|---|
| `build` | `task` |
| `test` | `build` (seq of the `build.submitted` under test) |
| `test-plan` | `build`; for a rework, `challenges` (keys) |
| `fix` | `findings` (only the chosen or harvested ones: `[{id, kind, file, severity, title}]`), `side` (`production` or `tests`) |
| `review` | `cover` (files), `diff` (base..head), `earlier` (`[{id, status, title, answer, decline}]` in its files: `answer` is the fixer's `done` or `declined`, `decline` its reason or null), `skipped` (IDs in its files the human didn't choose) |
| `arbiter` | `keys` (`[{id, finding, decline, insist}]`) |
| `challenge` | `draft` |
| `external-review` | `threads` (in its cover) |

### 1.4 Derived, never passed by main

- **The root** of a job is derived by `job-dispatch.sh` and `round.sh`: from the tree for a writing job (the root of the chain that owns the tree), from the round for a round job, from the merge for a fix. A first build has none. No script takes `--root` from main.
- **The approval** is an event: `gate.answered` for a gated dispatch, `fix.chosen` inside a loop. The second plan job and the challenge take the `gate.answered` of the test-plan step. A dispatch whose approval is missing or of the wrong kind is refused (`no-approval`).
- **After `loop.stopped`:** nothing more is dispatched (no `fix`, `make-round` or `replace` is owed); a complete round's merge is still owed, then `end-card` with reason `stopped`. A fix that submits after the stop gives the fact `no-review:<seq>`.

## 2. Script outputs

### 2.1 `owes.sh --effort DIR [--session ID]`

It prints one JSON object per root, sorted by root:

```json
{ "root": 4,
  "owed": { "step": "merge", "args": { "round": 9 } },
  "facts": [ { "key": "no-review:4", "words": "build 4 has no review" } ],
  "waiting": [ { "job": 11, "since": 12 } ],
  "loop": { "chosen": 20, "rounds": 1, "cap": 3 } }
```

| Field | Meaning |
|---|---|
| `owed` | the one step owed inside an agreed step, or `null`. Steps: `make-round`, `merge`, `choose` (a gate), `fix`, `replace`, `end-card` (a gate), `plan-rework`, `plan-gate` (a gate), `replies` (a gate), `comments` (a gate), `end-job` |
| `facts` | next-step facts: `no-review:<seq>`, `external-review:<seq>`, `review-requested:<seq>`, `head-moved:<seq>`. A fact answered by `fact.answered` is not listed again |
| `waiting` | open jobs (dispatched or assigned, no end) with the seq they started at; never a reason to hold |
| `loop` | the live loop on this root, or `null` |

A root that is closed, or has nothing owed, no facts and nothing waiting, is not printed.

### 2.2 The others

| Script | Prints |
|---|---|
| `harvest.sh --merge SEQ` | `{ "targets": [ids], "deadlocked": [ids] }` |
| `busy.sh --tree PATH --kind KIND` | `{ "busy": false }` or `{ "busy": true, "by": [job seqs] }` |
| `job-dispatch.sh --check …` | `{ "ok": true }` or `{ "ok": false, "refusal": "<key>" }`. Keys: `type-misfit`, `hot-agent-busy`, `own-commit`, `tree-busy`, `no-approval`, `loop-stopped`, `second-replacement` |
| `<step script> --check …` | for a repeated step: `{ "ok": false, "refusal": "done-already", "by": SEQ }` |

## 3. Case folders (Stage A)

```
cases/<id>-<slug>/
  fixture.sh      # only calls "$EV" (ev.sh) lines, in order; sets EV's session with --session
  expect.json     # the expected output
  command         # one line: the script under test and its args, run from the case's effort
  why.md          # 1–3 lines: what the case proves and where the rule comes from
```

The runner makes an empty effort per case, runs `fixture.sh`, runs `command`, and compares the output with `expect.json` by `jq -S`.

### 3.1 `ev.sh` as fixtures call it

```
"$EV" --session S1 --type TYPE [--root SEQ|self] [--round SEQ] [--job SEQ] [--agent ID] --body 'JSON'
```

It prints the new seq. Fixtures capture it: `b=$("$EV" …)`.
