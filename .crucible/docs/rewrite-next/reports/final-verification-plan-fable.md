# The final verification plan: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `final-verification-plan.md` in full, against my review of the acceptance bar and my step 4 verdicts.

**Not done:** I did not reread acceptance v2 or the built step 4 fixes. The runner counts are Dev Beta's.

## Verdict

**The plan is sound, and I approve it with five corrections.** All five are small and none needs a new design.

**On the go.** Dev Beta reports that the owner delegated the start to my approval. I didn't hear that, and a relayed message can't make my review the owner's go. What I give is a review: the plan is right once the corrections are in. Starting is Dev Beta's act, under the instruction the owner gave Dev Beta. The plan only runs tests in the sandbox and commits nothing, so I see no risk in it starting.

## The five corrections

1. **No call to a tracker with the owner's login.** F1 lists `installed-run`, which holds a live read of a GitHub issue. Remove those lines for this run, don't run `tracker-run`, and put the stub `gh` and `glab` first on the path for every runner and every agent run. Add it to "Rules throughout".
2. **Fingerprint what runs, not only the source.** The runs use the installed copy in the sandbox. Record its hash as well, or prove at each setup that it was installed from the frozen source.
3. **Say what counts after a prose fix.** Section 1 says a run with a different hash doesn't count. Section 5 keeps the other kinds' runs after a prose fix, which changes the hash. Make the rule: earlier runs count when the difference between the two hashes is only the named definition's prose file, and the difference is saved beside the result.
4. **One ask in the interactive set.** The new command hook's live cell is headless. In the interactive build, add one compound command that is refused with its message, and one plain command that reaches the human. The probe showed both once; the final run should show them with the real hook.
5. **I pick the sample.** Section 6 says I read a sample of cells. I'll choose them from the score files, so save every cell's raw output, not only the ones scored red.

## What is right

- **Control first** in F2, with every framework hook removed.
- **A framework bug means a full rerun,** never only the failed cell.
- **Two fix rounds, then report.** That stops the loop the owner has ruled out.
- **Three tries is a finding for the owner,** never switched on in the run.
- **The spread of text lengths** is reported, as I asked.
- **The owner's page** carries the honest limits and the scripted-only list.

## What I'll check in the results

- R1: zero gave up, and the larger part accepted at the first stop.
- That no refusal in any run is about a length.
- The control: red on every cell, for the reason the cell names.
- The parked cases with real agents, since step 3 proved them with a stand-in only.
