# Dev Beta [Backoffice]: round 3 proposals against real work

Read only. Sources: PSWS-1728, 1815, 2123, MRs !29 and !37.

## The six proposals

1. **`noticed` with `security` and `for`: fits, with two fixes.**
   - Real cases fit: PSWS-1728's handoff "audit integrity (forging a LogEntry)" becomes `for: "observability"`. A hard-coded token at `app/Services/KeycloakService.php:50` becomes `security: true`.
   - **Fix 1: `for: "security"` must imply `security: true`.** In the example, "evals user input, for security" would not get the security floor, so main would not hear about it first. On !37, 2 of the 9 items went to security seats. A security handoff is still a security concern.
   - **Fix 2: keep the kind for security items.** Draft 2's `found.kind` separated `secret` from `instruction`, meaning text that tries to steer an agent. Merging them loses that split, and main acts differently on each: a secret can't be quoted, while an instruction has to be ignored. Suggest `security: "secret" | "instruction"` instead of `true`.
2. **The test-plan event names: fit.** PSWS-1815's plan grew from 14 to 26 tests in one rework, which maps to one `challenged` and one `updated`.
   - **Missing:** the human's comment at the plan gate. "Add the 401 case" gives a new draft too. Say whether that is a `test-plan.updated` with no challenge answers, and whether it is challenged again.
3. **No `files` in `build.submitted`: fits, on one condition.** That condition is that nothing ever rebases or rewrites the effort branch. We did rebase !37 onto main, with conflicts in 2 files. That must happen only in the landing step, never on the effort branch. Otherwise draft 2's reason for keeping `files` in the log comes back.
4. **The report path in every submission: fits.** Nothing breaks.
5. **A finding inside its item: fits !37.** One bot note held 9 items; each valid one carried a single claim.
   - **Allow a list,** or say the item is split, for an item that holds two separate claims. That is the external-review flow's F-03a/F-03b case.
   - **Still missing from round 1:** a "the human decides" judgement. On !29 the triage used DISCUSS; `answered` is for a question we can answer ourselves.
6. **`answers` keeps its name: fits.** Its values differ by event (`done/partly/declined`, `fixed/open`, `applied/cannot`). That's fine because the event kind tells them apart.

## The timeline

- **§4, external review, misses the landing and the push.** Our replies to valid items said "fixed in eb49b45" (!37) and "§2 — fixed in 51e2171" (!29). The fix commit has to land and be pushed, each with its own go, before step 6's replies can name it. Also say who writes a valid item's reply. The schema gives a `reply` only to the other judgements.
- **§1 and §3** match how we worked.

Nothing else would break.
