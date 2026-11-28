## 🔍 Code Review · claude-code-crucible · round 2

**Verdict:** Approved with follow-ups

**Summary:**
- Realistic: 12 (1 MEDIUM · 11 LOW)
- Edge cases: 2 (2 LOW)
- Speculative: 10
- Needs your decision: 0
- Resolved this round: 25

**Reviewers:**
- Shell Script Reviewer
- Lens Consistency
- Lens Security
- Lens Compatibility
- Lens Self Documenting Code
- Execution Test

**Files:**
- `lens-test-quality-reviewer.md`
- `render-md.sh` · flow-review
- `render-md.sh` · flow-testing
- `SKILL.md` · flow-implementation
- `SKILL.md` · flow-review
- `SKILL.md` · flow-testing

### Realistic (12)

**Execution Test**

1. **MEDIUM** · Tracking · `SKILL.md:135` · flow-review: a chosen or promoted speculative item cannot be recorded, filed by the reviewer, or retired from the list → define the speculative lifecycle: elect, file as a finding, retire the entry
   - Trigger: the human chooses a speculative item by number
2. **LOW** · New · `SKILL.md:183` · flow-implementation: the question has no follow-ups-only option, so it can shrink to one choice → add a follow-ups-only option
   - Trigger: only one Address option has items
3. **LOW** · New · `SKILL.md:185` · flow-implementation: an undecided needs-your-decision item has no default → re-ask until each needs-your-decision item is answered
   - Trigger: the human answers 1, 4 while an edge-case HIGH awaits a decision
4. **LOW** · New · `SKILL.md:186` · flow-implementation: where rulings show, and the hold rule covering only security, are unstated → show one ruling line per item; widen the hold to data integrity and safety
   - Trigger: the human picks re-check first
5. **LOW** · New · `lens-test-quality-reviewer.md:56`: the reviewer has no re-check variant: input file and output use are undefined → define the re-check input and that its plan revision is not persisted
   - Trigger: the human picks re-check rejected first
6. **LOW** · New · `SKILL.md:125` · flow-review: PENDING past the re-entry reads as never briefed, but unchosen follow-ups stay PENDING → say unchosen follow-ups stay PENDING by design
   - Trigger: a follow-up the human did not choose
7. **LOW** · New · `SKILL.md:76` · flow-testing: draft test numbers in reasons clash with the renumbered render → cite tests by name in reasons
   - Trigger: the reviewer cites a draft test number in a rejection reason

**Lens Consistency**

8. **LOW** · Tracking · `SKILL.md:133` · flow-review: conflicts are now numbered under the relay, but a decided conflict has no recording or brief route → say how a decided conflict is recorded and briefed
   - Trigger: a lens emits a conflict note in a flow-review swarm
9. **LOW** · Tracking · `SKILL.md:112` · flow-testing: Plan conformance names the reviewer as its source, but the reviewer has no such field → name both sources: tests-developer counts and the reviewer plan findings
   - Trigger: every flow-testing test review render

**Shell Script Reviewer**

10. **LOW** · New · `render-md.sh:506` · flow-testing: the Approved line lists numbers in stored order, e.g. 1, 2, 4, 3 → sort the numbers ascending
    - Trigger: an amend moves a test so its number changes
11. **LOW** · New · `render-md.sh:362` · flow-testing: a prose builds-on entry keeps a slash inside a code span → show prose builds-on entries as plain text
    - Trigger: a builds-on entry written as prose, like helper in tests/x.sh
12. **LOW** · New · `render-md.sh:35` · flow-review: the header says no value renders a link, but bare URLs still autolink → qualify the claim to inline and HTML links
    - Trigger: a finding cites a bare https URL and the file is viewed on GitHub

### Edge cases (2) · not recommended to fix

**Shell Script Reviewer**

13. **LOW** · `render-md.sh:326` · flow-review: a line:col location is read as part of the file name
    - Why edge case: the contract allows only file:line and file:start-end
14. **LOW** · `render-md.sh:355` · flow-testing: a backslash cancels the plain-text escape after it
    - Why edge case: only builds-on allows a backslash, and it needs a name collision

### Speculative (10) · not recommended to fix

**Lens Compatibility**

15. `review-arbiter-verdict.schema.json:8`: re-checking a speculative item or a rejected test reuses a verdict that requires severity
    - Real if: the verdict is validated and an invented severity is rejected

**Lens Security**

16. `test-plan-verify.sh:634`: a plan changed during authoring and restored before the check goes unseen
    - Real if: someone other than tests-developer can write the plan mid-dispatch
17. `SKILL.md:76` · flow-testing: arbiter prose shown under a plan render could mimic plan sections
    - Real if: arbiter prose is pasted verbatim instead of one line per test
18. `render-md.sh:358` · flow-review: a whitespace-only reviewer name renders as a thematic break
    - Real if: the reviewer field ever comes from report text

**Shell Script Reviewer**

19. `test-plan-verify.sh:192`: a relative plan path starting with a dash is read as a cat option
    - Real if: a caller passes a relative path starting with a dash
20. `test-plan-validate.jq:414`: an unapproved unit-first plan in flight fails render, challenge and approve
    - Real if: unapproved unit-first plans are in flight when this lands
21. `render-md.sh:355` · flow-review: two reviewer ids that title-case to the same name give two identical groups
    - Real if: an artifact mixes lens-x and lens-x-reviewer
22. `render-md.sh:333` · flow-testing: a builds-on folder and a file with the same segments render the same label
    - Real if: a plan lists builds-on X/ beside a file X
23. `render-md.sh:396` · flow-review: ./a/f and a/f for one file get a dot label
    - Real if: reviewers in one swarm emit ./-prefixed and bare locations
24. `render-md.sh:595` · flow-review: a missing id fails only the item map after the Markdown was written
    - Real if: an artifact is hand-edited outside the scripts

### Resolved (25)

- **Shell Script Reviewer** · `render-md.sh:389` · flow-testing: always show the file on repair and delete entries
- **Shell Script Reviewer** · `render-md.sh:365` · flow-testing: match test directories and word-bounded test or spec tokens
- **Shell Script Reviewer** · `render-md.sh:346` · flow-testing: show the rejected count only once the reviewer section exists
- **Shell Script Reviewer** · `render-md.sh:296` · flow-review: size the fence to the longest backtick run plus one
- **Lens Self Documenting Code** · `render-md.sh:59` · flow-testing: state exactly which headings and labels carry counts
- **Lens Self Documenting Code** · `render-md.sh:279` · flow-review: point the rules entry to the header WHY block
- **Lens Self Documenting Code** · `test-plan-verify.sh:188`: keep the header as the single rationale
- **Lens Compatibility** · `test-plan-validate.jq:411`: enforce the order only on bodies being written, never on a stored plan
- **Lens Compatibility** · `lens-test-quality-reviewer.md:64`: tell both: keep e2e tests first and renumber after a move or restore
- **Lens Compatibility** · `render-md.sh:439` · flow-review: print the number-to-id map from the renderer and use it in the prose
- **Lens Compatibility** · `SKILL.md:53` · review-core: state at most 100 characters in review-core
- **Lens Consistency** · `SKILL.md:123` · flow-review: render the Spec line after the title
- **Lens Consistency** · `render-md.sh:373` · flow-review: pick one shape in review-report-standards and follow it everywhere
- **Lens Consistency** · `review-arbiter.md:10`: widen the arbiter's mandate and verdict, or drop the plan re-check
- **Lens Consistency** · `SKILL.md:135` · flow-review: point to flow-implementation section 5 and keep only the recording mapping
- **Lens Consistency** · `SKILL.md:183` · flow-implementation: say a chosen MEDIUM or LOW opens a fix round, and align the loop text
- **Lens Consistency** · `SKILL.md:115` · flow-review: reword to the new relay
- **Lens Consistency** · `SKILL.md:121` · flow-review: name both fields in the persist sentence
- **Lens Consistency** · `SKILL.md:92` · review-report-standards: document the fallback like the speculative one
- **Lens Consistency** · `SKILL.md:120` · review-report-standards: list for your decision as a counted class, or drop it
- **Lens Security** · `render-md.sh:320` · flow-testing: show the folder for new and deleted files
- **Lens Security** · `SKILL.md:186` · flow-implementation: apply only promotions; a demoted CRITICAL or HIGH stays a human decision
- **Lens Security** · `render-md.sh:289` · flow-review: reuse the test-plan forbidden-character set and escape HTML and links
- **Execution Test** · `SKILL.md:78` · review-report-standards: show the trigger on a needs-your-decision edge case
- **Execution Test** · `CLAUDE.md:76`: cite flow-implementation section 5 and flow-review section 5d

### Round history
- Round 1: Shell Script Reviewer, Lens Consistency, Lens Security, Lens Compatibility, Lens Self Documenting Code, Execution Test
- Round 2: Shell Script Reviewer, Execution Test
