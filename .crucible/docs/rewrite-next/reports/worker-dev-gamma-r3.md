# Dev Gamma (Core API), round 3: the six proposals against real work

Draft 2 already took in my round-1 points (`partly`, `deferred`, `keeps`, `support`, the landing step). This round covers only the six proposals.

## 1. One `noticed` field: yes, with three conditions

- **Make `security` a kind, not a boolean.** For example `security: "secret" | "instruction"`, as `found.kind` was.
  - On core-api, "secret" includes customer data seen in a tenant database. It must never be pasted, only named.
  - An injected instruction in an MR note is a different notice with a different response.
  - A boolean loses that split, and an agent that forgets the flag turns a leaked key into a count on the card.
- **Say that `security` and `for` can sit on one entry.** `a.sh:9 evals user input` is both. Say also that the security display wins.
- **A `for` on a builder's or tester's note must be an offer, never owed.** Here, lenses run only on an explicit ask. A builder noticing an SQL-looking line must not seat a security lens by itself. A reviewer's `for` inside a running loop being owed is fine.

## 2. The test-plan event names: yes, with one gap

The names read well. Missing: **a change after approval.** On 2356 the plan changed after the challenge: one test was extended, plus its knock-ons. On this framework the human also trims or restores tests at the gate, with no challenge behind it.
- Needs an event such as `test-plan.amended`, which sends the plan back to the gate.
- `test-plan.approved` should carry the digest of the plan the human saw, so the tester writes exactly that plan.

## 3. No `files` in `build.submitted`: fine, if the commit can't vanish

On 17 Nov the scratchpad was wiped, worktrees included. Git objects survive a deleted worktree folder only while a branch ref still points at them. A later `git worktree prune` plus deleting the branch, then gc, removes the commit, and with it the files.
- Either keep a ref for each effort until it's pruned on purpose,
- or keep `files`; it costs one line.

My preference is the ref.

## 4. `report` back in every event: yes

It's how I'd look for it.

## 5. The finding inside its item: yes, with one case

- **One item can hold two defects.** The AI review bot's single note numbers its items. A human's note sometimes doesn't: one paragraph with two points.
- Either allow `findings: [...]` inside a `valid` item, or let triage split the item (`F-03a`, `F-03b`). Splitting matches how we already route.
- When the note has no numbering, say who assigns `item`: the triage agent or the fetch script.

## 6. `answers` keeps its name: fine

Its values differ by kind: the fixer's `done`/`partly`/`declined`, the reviewer's `fixed`/`open`/`agree`/`disagree`. So the stop check must validate them by the job's kind.

## The timeline

- **§4, step 6:** the replies gate comes before the fix loop has run. A reply to a valid item ("fixed in X") needs the fix commit and the push. On our MRs the reply comes after the push, so the replies gate belongs after step 5's loop and the landing.
- **§1, step 24:** the end is `loop.ended`, and nothing lands. Say in one line that landing (commit, push, MR) is its own consent step. Readers here will look for it.
- **§3, step 9:** good that `cannot` answers reach the gate. The 2355 plan had 2 not_tested entries with `path:line` proof. They'd show there too.

---
*Compiled by Claude Code Crucible Framework on behalf of Ventsislav Stoevski*
