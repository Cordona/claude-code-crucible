# Settle the spec: the branches

The branches off SKILL.md's The spec: an approved spec and its revision, a left draft, a typed answer, a gate that fails, and where each run goes once settled. `<context.sh>`, `<crucible.sh>`, `<render-spec-gate.sh>` and `<views>` are as SKILL.md sets.

## The spec's gates

The revision offer and the approval are gates, as SKILL.md's Never and Always set. The offer is shown as The spec step 4 shows the approval, with its own plan file (step 2), the label `spec-offer` and no `--effort`, unlike the approval.
- **The answer:** match it to an option with `(Recommended)` ignored, and quote a label without it.
- **The pipe exits non-zero** (the exit is `open-gate.sh`'s, so read the stderr), or `--approval-plan` does (read its stderr the same way): a `render-spec-gate.sh:` line that isn't `install:` is a refused input. At the offer, fix the reasons it names; at the approval, "the draft changed since its plan" means run `--approval-plan` again, and any other draft problem it names means write a new draft (The spec step 3). Then run `procedure-approval-gate`'s step 1 again, once. A second refusal, an `install:` line or no renderer line: show the human the stderr, and end the spec talk with `stopped: spec not settled`.
- **The gate can't be shown or asked otherwise** (a failed `--question` or stdout that isn't one JSON object with those three fields, or `procedure-approval-gate` won't load or reports the plan not shown): tell the human what failed, word for word, and end the spec talk the same way.

## Steps

1. **Settled already?** From The spec step 1:
   - **On Resume with an open spec talk** (SKILL.md's Resume): The spec step 2, then step 3 below.
   - **`SPEC: approved`, and a change to its goal, done-when or scope** (an ended grill, a ticket read after approval, a settled answer from SKILL.md step 4's weighing, or a change a flow hands in from its plan gate or a Changes item): The spec step 2, then the revision offer (step 2).
   - **`SPEC: approved`, and the human's own ask to revise the spec:** The spec step 2, then The spec step 3 as a revision, with no offer.
   - **`SPEC: approved` and nothing changed it:** settled (step 5).
   - **`SPEC: none` with a draft left:** The spec step 2, then step 3.
2. **Offer the revision at its gate.** The plan file is `{"case": "revision", "reasons": [...]}`, written with the Write tool, its reasons from your judgment in the shape `render-spec-gate.sh --help` sets: what changed, and where. The label is `spec-offer`, with no `--effort`. Act on the answer as step 4 sets.
3. **A draft is left whose text isn't the newest approved spec's** (a talk a break cut off): Read it in full.
   - **No approved spec yet:** go on from it, never from memory, as the current draft of The spec step 3; a complete one goes to The spec step 4 as it is.
   - **An approved spec:** ask one AskUserQuestion, its question giving the draft's absolute path, with the options `Go on from it (Recommended)` and `Start fresh`. Going on: it is the current draft of The spec step 3. Starting fresh: The spec step 3 from the approved spec. A typed answer that is neither: answer it as the turn's last message, and ask the question again at the human's next message.
4. **The human's answer at a spec gate.** After any answer but the one to the gate question this spec talk last asked, the same draft needs its gate shown again. "No spec", "just build it" and "stop the work", typed at any gate, follow their own rules below, never a typed-answer rule.
   - **"Revise it":** The spec step 2 when `standard-spec` is not yet loaded, then The spec step 3.
   - **"Keep it as it is":** nothing changes, and the change that led to the offer is not made (step 5).
   - **A typed answer at the revision gate:** one that asks to revise is "Revise it"; one that declines is "Keep it as it is"; any other: answer it as the turn's last message, and show the revision gate again at the human's next message.
   - **A typed answer at the approval gate that approves the spec as it is:** like any typed answer, it is no approval: show the approval gate again (The spec step 4), its `--approval-plan` run with `--typed-approval`, which prints the line that names the approve option to pick. Never run `<context.sh> spec --approved` without the gate's recorded answer.
   - **Any other typed answer at the approval gate:** one that asks for a change or answers an open point: write it into a new draft, then The spec step 4; any other (a question, a remark): answer it as the turn's last message, and show the approval gate again (The spec step 4) at the human's next message.
   - **`NO-SPEC-GATE`:** show the approval gate again (The spec step 4); never copy the draft or work around it.
   - **The human's own "no spec" or "just build it", at any point** (discovery included): The spec step 3 with a short draft, its first `--approval-plan` with `--spec-needed`; in a revision, show the line `spec_needed`, and drafting ends with nothing changed (step 5).
   - **"Stop the work":** the drafts and the docs folder stay in the effort; stop (`stopped: spec not settled`).
5. **Settled:**
   - **Run by a flow** (a change from its plan gate or a Changes item, or no approved spec), **or after a ticket read in SKILL.md step 5:** hand over as SKILL.md step 8 sets, with no "what next?"; after "Keep it as it is", also tell the flow the spec is kept and the change not made; with `SPEC: none` still, `stopped: spec not settled`.
   - **Run during discovery** (the human's own ask before SKILL.md step 4): go back to SKILL.md step 1, then steps 2–4.
   - **Run from SKILL.md step 4:** go back to it, which goes on to "what next?".
   - **Run from SKILL.md step 7 after a grill:** go back to it, which asks "what next?".
   - **Run alone on the human's own ask, once the spec is approved:** once the approved spec is written, SKILL.md step 7 asks "what next?" again. With nothing changed: hand a running flow its line as SKILL.md step 8 sets, its `latest` with `--line context_unchanged`; with none running, show the line `context_unchanged`. Then end the turn with no "what next?".
   - **Run from Resume:** back to SKILL.md's Resume, with the spec talk settled for this session.
   - Every stop here ends as SKILL.md step 8 sets, its step named `references/settle-spec.md` step `<n>`.
