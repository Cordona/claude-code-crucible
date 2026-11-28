# Stages B and C: Fable's answer (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `plan-b-c.md`. Talking only; nothing here is a go.

**What I did:** read the plan, the real writer's contract (`event-write.sh --help`), the lab's scripts by name and size, and the expected outputs of the cases added since my check. I reran Stage A on a frozen copy in my own scratch space: **72 of 72 pass, and the output is identical to `evidence/stage-a.out`.** A grep of `lab/` finds no case name and no finding ID.

## In short

1. **Yes, write through the real writer.** It is the right step, and it does more than add realism: it closes a hole Stage A can't see.
2. **Use two more real pieces, and no others:** core's gate everywhere, and the adaptive flow in one run. Not the worktree cut.
3. **Add three experiments now:** a permission-mode run, a run with real judgement, and a timing check on a long log. After those, what is left is ordinary build risk.
4. **Stage A is trustworthy for what it proves.** It proves the rules in one process, one step at a time. It does not prove them under several agents ending at once, or split by component.

## 1. The real writer, and what else to make real

### The writer: yes, for three reasons

- **It makes the refusals atomic.** In the lab only `ev.sh` holds the lock. A step script checks "is there a merge already?" and then writes, with nothing held in between. Stage A runs one step at a time, so this passes. In run C1 three reviewers end together and main may be woken three times. The real writer gives each type a rule that sees the new event and all earlier ones, **under the lock**. Put "done already" and the link checks there, and a repeated step is refused by the writer itself. This is the strongest reason, and it is a design finding for the real thing: the repeat rules belong in the events' rules, not in the step scripts.
- **It tests the held-lock path** (exit 6) with the real behaviour, which is my missing Stage B case.
- **It shows where the proposed events don't fit core.** Two points will surface at once, and both are worth knowing now:
  - **The envelope.** The real one is type, seq, time, writer, session and body. The lab's adds root, round, job and agent on top. Either those go into the body, or core's envelope changes. I would put them in the body: the rules can read them there, and core stays untouched.
  - **The session id.** The real writer takes it from the environment. Whether a hook's process has that variable is not known; hooks get the session id on their input. The orphan rule stands on this field. Check it in the first Stage B case.

**Two conditions:**
- **The copy is exact.** Record its hash against new-rewrite's. If the copy must be changed to make the spike work, that change is a finding, listed in the results, not a quiet patch.
- **"The rules become the first draft of the real rules" is true for what they say, not for the files.** The spec says nothing from the lab becomes new-rewrite code. Keep that; carry the knowledge over, and write the real rules again when the build is approved.

### Core's gate: yes

- Every dispatch in the model rests on an approval, and after my last check that approval is an event. In the real thing it is `gate.answered`. The lab's `gate.sh` is 16 lines standing in for the piece the whole refusal list depends on.
- The gate brings its own hooks and its own prose. That is the point: a real session will have both, and "thin prose" should be measured with the gate's skill counted, since main reads it.
- It also tests D4 where it happens: the human answers in their own words at a gate, and main turns that into a query.

### The adaptive flow: one run, not all

- This is the one claim of mine the spike doesn't test: that "facts" and an agreed flow don't compete. And a real session will have the flow's stop hook and the job scan's stop hook together. What two stop hooks do when both have something to say is cheap to learn now and awkward to learn after the build.
- One run is enough: C1 again, with a flow agreed first (build, then review). Watch what main is told at each stop, and by which hook.
- It needs step declarations for two lab pieces. If that turns out to be more than an hour's work, that is itself the answer to "does the job model fit the catalogue", and should be reported instead of forced.

### The worktree cut, the commit and the push: no

They supply a folder and a commit. Their own evidence is some 300 checks. Nothing the spike claims depends on how the tree was made. Pulling them in would bring the identity, signing and the remote, and that is the build.

**The rule I'd use:** a real piece belongs in the spike when the claim rests on how that piece behaves. When it only supplies a fixture, a stand-in is right.

## 2. What would still stand between B and C and a confident build

### Add now: cheap now, expensive later

1. **A permission-mode run.** Both probes ran with permissions bypassed. The owner's sessions don't. An unattended loop meets its first unlisted Bash command inside a background builder, with nobody there to answer. I don't know what happens then: a prompt that waits, or a refusal. Either one stops the loop, and the fix is a design choice, not a patch. Note that a PreToolUse hook can answer "allow" as well as "deny", so the job's scope hook could grant what the job covers. One short run in default mode shows which problem we have. **This is the one I would not skip.**
2. **One run with real judgement.** Every stand-in does what its `act` says, so nothing has shown an agent that has to think and still end its job properly. One run, last, with no `act`: a builder makes a small real change, a reviewer with no Bash reviews it from the tree, the builder fixes, the same reviewer re-reviews. Judge only the job discipline, not the review:
   - is the report valid at the first or second stop;
   - does the agent stay in its scope without refusals;
   - does the hot agent take its second job from the file;
   - can a reviewer with Read alone find its way around the code. The lab reviewer has no Grep or Glob; a real one will need them.
3. **A long log.** The scan runs at every stop of main, and the writer's rule reads every earlier event on every write. Generate two thousand events and time `owes.sh` and one write. It takes minutes to check, and a slow stop hook would be felt in every turn.

### Already in the plan, and decisive

- **C10** decides whether a reopened session has a new id, which the orphan rule needs.
- **C2, three times,** decides whether main drives the loop reliably.

### What B and C can't give, and shouldn't try to

- **The real agents' prose.** Whether a real builder, tester and reviewer behave is learned from the first build stage, with a cap of one, as already agreed.
- **Signing and committing inside a stop hook, within its time limit.** The old rewrite has live evidence and a known workaround; it is build work.
- **Where "70%" comes from.** Still open; it blocks nothing.

After B, C and the three additions, I would call the model proven and the remaining risk the normal risk of a build that is run live at each step.

## 3. What to doubt in Stage A

Not the result: it reproduces, the authors were separate, and the scripts hold no case knowledge. What it doesn't show:

1. **One process at a time.** Section 1: the repeat refusals are check, then write. Fixed by the writer's rules, and worth one Stage B case that runs the same step twice at the same moment.
2. **One `owes.jq`, not rules per component.** The script agent said so. Stage A passes either way, so "each component declares its own rule" is still a claim. Try the split in the lab. If a rule needs another component's events to answer (the replies owed on an external review need the loop's state), write down which: that is the coupling the real design has to settle, and it is better found here.
3. **The arbiter gets no insist reason, because no event carries it.** The same is true of the fixer's decline note. Both live in report files. So the arbiter's job should name the two reports by path, not copy text into the payload. That also fits the rule that a report is a sealed file and events point at it.
4. **The report path is guessed before the seq exists.** The plan's fix (the writer fills it in under its lock) changes the writer. A smaller one: name the report by something known before the write, and leave the writer alone.
5. **My own reading has a limit.** I read 20 of the first 60 fixtures line by line and none of the 12 added since; for those I checked the expected outputs only. They look right, including the changed a2-10 and the new a2-18.

## 4. Order I would run

1. The writer's copy and the adapter; Stage A again through it.
2. Stage B, starting with the session id and the held lock, and including the permission-mode run.
3. The driver's dry run for each C run.
4. C1 twice, C2 three times, C3 to C6, C10.
5. The flow run, then C7 to C9, then the run with real judgement.

Stop and report at the first break, as the spec says. A break in step 1 or 2 is the cheapest thing this spike can find.
