# Elevated review: software-development pieces and core changes

Judge from results and the constitution. Do not review implementation: no script code, no line-level findings.

## Scope

- Software development: git-identity, git-commit, git-worktree, git-mount, git-push, trackers, code-context. These are under `new-rewrite/domains/software-development/core/main-thread/`.
- Core changes: the gate's recorded choice, the step catalogue (`flow-step.json` and the dynamic flow), and the --help contract across all 87 scripts.

## What to read

- The constitution: `.crucible/docs/rewrite-next/constitution.md`
- The help rule: `.crucible/docs/rewrite-next/help-rule.md`
- The specs: `.crucible/docs/rewrite-next/specs/` (software-development-domain.md, crucible-gate.md, crucible-context.md and the others)
- The live evidence: `.crucible/docs/rewrite-next/evidence/*.out`, and the `*-run.sh` beside each one, read only for what each case claims
- The worktree design and the parked agent-run map: `.crucible/docs/rewrite-next/reviews/git-worktree-design.md`, `agent-run-parked-map.md`
- The SKILL.md files of the pieces in scope. Their `--help` is each script's contract; run `sh <script> --help` on the ones you sample.

## Facts from tonight's run, for you to check against the evidence

- All 15 evidence runs exit 0. git-commit 86/86, git-worktree 311/311, git-mount 161/161, git-push 85/85; the rest are narrative runs whose outputs match the pre-trim baseline except for hashes, ids, fresh scratch keys and help text.
- All 87 scripts were executed with real arguments (not just --help), proven by a logging `sh` shim over every evidence run.
- Every help was trimmed to one template: two blind reviewers, a writer, then two blind verifiers per script, and every script passes both verifiers. A checker passes on all 87. Only help text changed; the code is byte-identical outside the help.
- Help lines: 1,624 before, 1,761 after. Big helps shrank (45 to 25); small ones grew because they gained Exit, Requires and Writes sections.

## Questions

1. Does the evidence prove the pieces do what their specs promise, for both success and refusal? Name any promise with no evidence.
2. Do the pieces comply with the constitution? Check small single-job scripts, events as facts, a domain-agnostic core, floating pieces, judgement left to main and the human, and no micromanaging prose.
3. Is the --help contract right for its audience: agents first, and readable by a human? Is it consistent, not verbose, and sufficient? Is 1,761 lines the right shape, or is something systematically noisy?
4. Fat scripts across the whole new-rewrite: which ones still break the "good example" bar? Rank them.
5. Your earlier toolbelt changes (one home for the repo rule and timeout runner, main's tools apart from internal ones, events-read.sh failing closed): are they still the right next moves? Is anything more urgent?

## Answer

Write your verdict to `.crucible/docs/rewrite-next/reviews/elevated-review-verdict.md`:
- A verdict line: aligned, aligned with changes, or not aligned.
- Then the findings, each with the evidence file or constitution clause it rests on.
- Then a ranked list of the changes you would make.

Send Dev Beta a one-line message when it is written.
