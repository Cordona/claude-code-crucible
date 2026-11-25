# Standards plugins: alignment report

All 8 copied from `rewrite/domains/software-development/core/plugins/standards/` to `new-rewrite/domains/software-development/core/plugins/standards/`, same layout. Nothing under `rewrite/` or `plugins/tech` touched. Nothing committed.

In every `SKILL.md` description, "Injected into the agent's first message when loaded" now reads "Injected into the agent's job by the dispatch." Everything else below is per plugin.

## Per plugin

**accessibility**
- Removed: the `standard-testing` / "its framework plugin" names in the description, and "a test that queries by role is `standard-testing`'s" (now just "Test code is out.").
- Unsure: nothing.

**clean-code**
- Removed: the skill names in the description's not-for list.
- Unsure: review.md says MEDIUM covers "tight coupling that blocks change or testing", but its Overrides say "it blocks testing" never raises a finding. Both are legacy text. I left them as they were.

**observability**
- Removed: the skill names in the description.
- Unsure: nothing.

**performance**
- Removed: the skill names in the description.
- Unsure: nothing.

**persistence**
- Removed: the skill names in the description, and `mcp__context7` from "verify it (… or WebFetch)". Neither code-builder nor code-reviewer has that tool, so it now says WebFetch only. Changed the `(§N)` references to the plugin's own section names (Atomicity, Concurrency, Durability…).
- Unsure: the short names ("Integrity", "Access patterns") are shorter than the real headings. They are clear enough, but not exact.

**security**
- Removed: the skill names in the description. In build.md, "record the `scan` step as not run" (a gate-field shape) now reads "record that the scan didn't run".
- Unsure: nothing.

**self-documenting-code**
- Removed: the skill names in the description.
- Unsure: review.md checks the placement bar "only when the brief gives the commit message's or the PR/MR description's full absolute path". I don't know if the new review job ever carries that path. If it never does, that bar and its MEDIUM "cross-artifact duplication" are dead for the reviewer.

**testing**
- Removed:
  - `references/test.md`. All of it was old machinery: `standard-code-test-report`, `standard-code-build-report`, `--kind test`, `mutation-copy.sh` and the "deviation" report status.
  - `references/untested-template.md`, which is a report format. It also clashes with code-tester's own `untested` shape: it has a `category` field, and `recommend` is `waive` where the tester uses `skip`.
  - In SKILL.md: the skill names in the description, and the "Following it writes only test files…" bullet. Code-tester already owns "tests only" and "break in a copy".
  - Also in SKILL.md: the category-naming rule and the `recommend: waive` / template wording. The waiver now reads "waived only by the human approving the plan".
  - `§6` and `§10` became section names.
- Unsure: the category rule ("when it falls under two, name it security or authentication") went with the template, because it only fed the `category` field. If the owner wants the category back, it belongs in the tester's report shape, not here.

## References to other files that stay

- **None to another skill, agent, flow or procedure.**
- **Within one plugin, build.md and review.md still point at their own SKILL.md's sections:** security `(A02)`/`(A03)`, observability `(Pillars by shape)`, performance `Rules 1–7`, accessibility `(section 4)`/`(section 7)`, testing's section names.
  - Why they stay: the SKILL.md body goes in with each role file, so the reader always has the target. Removing them would mean repeating the rule.
  - If the dispatch ever sends a role file without its SKILL.md, these break.
- **review.md items that name the job's inputs:**
  - self-documenting-code's "brief gives the commit message's … path";
  - testing's "a test not in the approved plan" and "its planned break".
  - Why they stay: they describe what the job carries, not another file.

## The tester question

Today no tester reference exists, and in the legacy only code-tester ever loaded testing. In new-rewrite, testing's SKILL.md + review.md go only to the testing-lens reviewer. Yet almost all of testing's SKILL.md is tester know-how. Question for the owner: should code-tester receive testing's SKILL.md body (with no role file, or a new `test.md`)?

What a tester would need from it:
- tests that can fail, and a bug fix's test red on the pre-fix code;
- the required categories (security, persisted data, concurrency, auth) and proven gaps;
- the smallest sufficient set;
- the public contract by code shape;
- the levels and when each is justified;
- the mock and boundary order (containers, then a config swap, then an HTTP stub; never a live system);
- golden fixtures: captured, masked, non-deterministic fields normalised;
- isolation, with no `sleep` and an injected clock;
- AAA and naming;
- speed;
- the "Any framework" concept table.

Mutation know-how lost with test.md, if the owner wants it back:
- break only the behaviour a test guards, never an implementation detail;
- a pre-fix check reverts the fix in the copy;
- run the project's own mutation tool there where one exists.

Code-tester already says "break in a copy", but not these.

Other plugins where a tester would clearly need something:
- **tech languages and frameworks:** test-framework idioms, and how to run a filtered test. That is the other agent's area.
- **persistence:** what makes a store test real, such as real-store integration and concurrency.
- **security:** "a hardcoded real secret is a finding in test and fixture code too".

The last two are minor. Persistence and security already reach the tester only if the dispatch loads them.
