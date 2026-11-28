# Building blocks inventory: plugins and standards

What the old rewrite's plugins are, what ties each one to the old rewrite, and what has to change before it works in new-rewrite under the job model.

ROOT is `/Users/cordona/IdeaProjects/cordona/claude-code-crucible`. The two folders hold 55 files: 19 SKILL.md, 35 reference files and 1 script.

## Conventions every plugin shares

These belong to the injection contract, not to any single file. Each plugin follows all of them.

- **Folder name:** `<kind>-<name>`, where the kind is `language`, `framework`, `standard` or `procedure`. The frontmatter `name:` must equal the folder name.
- **Frontmatter:** `disable-model-invocation: true`, `user-invocable: false`, and a `metadata.label` that the scripts print as the plugin's label. `metadata.base` is refused.
- **Role files:** these are what `plugin-files.sh` picks per role.

  | Role | Files it gets |
  |---|---|
  | builder | `SKILL.md`, `references/build.md`, and any `*-template.md` |
  | tester | `SKILL.md`, `references/build.md` or `references/test.md`, and any `*-template.md` |
  | reviewer | `SKILL.md` and `references/review.md` |

  `list-plugins.sh` refuses a plugin that has no `references/build.md`. standard-testing is the exception: its required file is `references/test.md`.
- **Severity sections:** each `review.md` grades with CRITICAL, HIGH, MEDIUM and LOW, the levels `standard-code-review-report` uses. `code-reviewer.md` starts grading from "your lens plugins' `review.md` Severity".
- **"Record it" lines:** each `build.md` and `test.md` uses them. They map onto fields of `standard-code-build-report` and `standard-code-test-report`: decisions, `open` items, not-run gate steps and deviations.

Under the job model, a **role** is a **job kind**: build, test or review. The table above becomes the mapping from job kind to files.

## Table 1: ROOT/rewrite/domains/software-development/plugins/

Paths are relative to `plugins/tech/`.

| Path | Kind | One job | Couplings to the old rewrite | What must change in new-rewrite |
|---|---|---|---|---|
| `languages/kotlin/SKILL.md` | language plugin | Kotlin/JVM rules: toolchain, null safety, data classes, coroutines, Flow, interop, lints | Description names `code-builder` and `code-tester`. Uses the shared conventions. | Rename the agent names in the description if new-rewrite's agents are named differently. |
| `languages/kotlin/references/build.md` | reference (build role) | Defaults, edge cases and the verification gate (Gradle/Maven steps, baseline compare) | Gate step keys `format`, `typecheck`, `lint` and `test` are `standard-code-build-report`'s gate keys (`report-iteration.json`, `build-report-check.jq`). "Record it" and "a gate step … doesn't run" map onto build report fields. | Keep the keys if the new build report keeps them; otherwise rename them to the new report's keys. |
| `languages/kotlin/references/review.md` | reference (review role) | Kotlin correctness defects and severity | CRITICAL/HIGH/MEDIUM/LOW, as the old review report uses them | None, if the new review report keeps the four levels. |
| `languages/php/SKILL.md` | language plugin | PHP rules: type juggling, null and array access, decoding, exceptions, strict types, lints | Description names `code-builder` and `code-tester` | Same as Kotlin. |
| `languages/php/references/build.md` | reference (build) | Defaults, edge cases and the gate (`vendor/bin` tools, phpstan baseline) | Gate keys `format`, `typecheck`, `lint` and `test`; "record it" | Same as Kotlin. |
| `languages/php/references/review.md` | reference (review) | PHP correctness defects and severity | Severity levels | Same as Kotlin. |
| `languages/rust/SKILL.md` | language plugin | Rust rules: errors, panics, casts, std traits, `unsafe`, async, ownership, clippy | Description names `code-builder` and `code-tester` | Same as Kotlin. |
| `languages/rust/references/build.md` | reference (build) | Defaults (Tokio, Axum), the `unsafe` edge case and the cargo gate, run offline | Gate keys `format`, `typecheck`, `lint` and `test`; "record it" | Same as Kotlin. |
| `languages/rust/references/review.md` | reference (review) | Rust correctness defects and severity | Severity levels | Same as Kotlin. |
| `languages/shell/SKILL.md` | language plugin | Bash/POSIX rules: quoting, strict mode, traps, injection, temp files, portability, shellcheck | Description names `code-builder` and `code-tester`. Lines 14 and 75 say "unless the first message names fewer platforms", which is the hook-built first message. | Rename the agent names. Keep "first message" only if new dispatch still hands over one composed message; otherwise say "the job". |
| `languages/shell/references/build.md` | reference (build) | Root, dry-run and destructive-step defaults, and the gate (shellcheck, `-n`, tests, guarded run) | Gate keys `lint`, `typecheck`, `test` and `manual`; "record it" | Same as Kotlin, and note the `manual` key. |
| `languages/shell/references/review.md` | reference (review) | Shell correctness defects and severity | Severity levels | Same as Kotlin. |
| `languages/typescript/SKILL.md` | language plugin | TypeScript rules: types, unions, async, Zod, naming, lints | Description names `code-builder` and `code-tester` | Same as Kotlin. |
| `languages/typescript/references/build.md` | reference (build) | Package manager default, monorepo edge case and the gate | Gate keys; "record it" | Same as Kotlin. |
| `languages/typescript/references/review.md` | reference (review) | TypeScript correctness defects and severity | Severity levels | Same as Kotlin. |
| `frameworks/laravel/SKILL.md` | framework plugin | Laravel rules: authorization, mass assignment, Blade and raw queries, validation, CSRF, queues, Eloquent | "Not for code with no language plugin loaded" and "adds no gate tool": the plan rule that a framework needs a language | None, as long as the new job record keeps "framework only with its language". |
| `frameworks/laravel/references/build.md` | reference (build) | Defaults (FormRequest, Policy, `$fillable`, `lazy()`) | "Record it" | None. |
| `frameworks/laravel/references/review.md` | reference (review) | Laravel correctness defects and severity | Severity levels | None, if the levels stay. |
| `frameworks/nextjs/SKILL.md` | framework plugin | Next.js App Router rules: Server Actions, route handlers, middleware, caching, routes | The framework-needs-language rule; "normally beside `framework-react`" | None. |
| `frameworks/nextjs/references/build.md` | reference (build) | Pages Router and authorization edge cases; "adds no gate step" | Names the gate concept; "record it" | None. |
| `frameworks/nextjs/references/review.md` | reference (review) | Check against current docs, and severity | Severity levels | None. |
| `frameworks/react/SKILL.md` | framework plugin | React rules: hooks, effects, state, keys, forms, RSC, hydration, output safety, React's a11y forms | The framework-needs-language rule; cross-references `standard-accessibility` | None. |
| `frameworks/react/references/build.md` | reference (build) | Compiler, `react-hooks` lint and server-cache edge cases; adds no gate step | "Record it"; names the gate concept | None. |
| `frameworks/react/references/review.md` | reference (review) | React correctness defects and severity | Severity levels | None. |
| `frameworks/spring/SKILL.md` | framework plugin | Spring Boot (Kotlin) rules: injection, transactions, JPA, web boundary, Security, compiler plugins | The framework-needs-language rule | None. |
| `frameworks/spring/references/build.md` | reference (build) | Compiler-plugin-not-enabled edge case | "Record it" | None. |
| `frameworks/spring/references/review.md` | reference (review) | Spring correctness defects and severity | Severity levels; "the needed change not recorded" (the build report) | None. |

## Table 2: ROOT/rewrite/domains/software-development/core/plugins/

| Path | Kind | One job | Couplings to the old rewrite | What must change in new-rewrite |
|---|---|---|---|---|
| `procedures/read-trackers/SKILL.md` | procedure plugin (skill) | Agent-side, read-only reading of GitHub, GitLab and Jira links in a dispatch's context, through `read-link.sh` | "the first message's Handling your context" (procedure-context's `agent-context-rules.md`, injected by the hook). The context file's `links` list (the context.cut event the hook names as `CONTEXT FILE`). `procedure-jira-auth`. The install path `${CLAUDE_CONFIG_DIR}/skills/procedure-read-trackers/`. `code-reviewer.md` lets the agent run this script in Bash. | Superseded. new-rewrite's `trackers` skill reads GitHub and GitLab issues at discovery and copies them into the effort's context, so agents never read trackers themselves. Jira is not covered there. |
| `procedures/read-trackers/references/build.md` | reference (build role) | Empty stub (title only), present so `list-plugins.sh` accepts the plugin | Exists only to satisfy the old role-file rule | Goes with its plugin. |
| `procedures/read-trackers/scripts/read-link.sh` | script | Classifies one link and reads it with a single bounded, timed-out read-only call (`gh`, `glab` or `jira.sh`) | `procedure-context/scripts/agent-context-url.jq`, the old link rule; new-rewrite's is `crucible-context/scripts/lib/link-rule.jq`. `procedure-jira/scripts/jira.sh` and `procedure-jira-auth/scripts/jira-curl-config.sh`. The context.cut event's `body.links` shape. | As the row above. If it were kept, all four paths and the context shape would need rewiring. |
| `standards/accessibility/SKILL.md` | standard plugin | WCAG 2.2 A/AA rubric in HTML/ARIA terms | Description says "Injected into the agent's first message when loaded" | Reword only if delivery stops being a composed first message. |
| `standards/accessibility/references/build.md` | reference (build) | What to record: no a11y check configured, a design conflict, an unresolved token | "Record it" maps onto the build report | None. |
| `standards/accessibility/references/review.md` | reference (review) | Review walk order, finding bar and severity | Severity levels | None. |
| `standards/clean-code/SKILL.md` | standard plugin | Structural rubric: contracts, responsibility, DRY/YAGNI, coupling, functions, dead code, layout | "Injected into the agent's first message"; collides with an installed skill name (see Install collision) | Install-name fix only. |
| `standards/clean-code/references/build.md` | reference (build) | Record each questionable extraction; build-so-that rules | "Record it" | None. |
| `standards/clean-code/references/review.md` | reference (review) | Finding bar and severity | Severity levels | None. |
| `standards/observability/SKILL.md` | standard plugin | Observability rubric: pillars by shape, log privacy, audit, levels, structure, metrics, traces | "Injected …"; install-name collision | Install-name fix only. |
| `standards/observability/references/build.md` | reference (build) | Record the codebase's shape, its pillars and the assumed alert owner | "Record it" | None. |
| `standards/observability/references/review.md` | reference (review) | Judge against shape; severity | Severity levels | None. |
| `standards/performance/SKILL.md` | standard plugin | Scaling rubric: cost model, N+1, bounded reads, caching, baseline | "Injected …"; install-name collision | Install-name fix only. |
| `standards/performance/references/build.md` | reference (build) | Record each optimization kept at clarity's cost | "Record it" | None. |
| `standards/performance/references/review.md` | reference (review) | Finding bar and severity | Severity levels | None. |
| `standards/persistence/SKILL.md` | standard plugin | Store-correctness rubric: guarantees, integrity, atomicity, isolation, migrations, durability | "Injected …"; install-name collision | Install-name fix only. |
| `standards/persistence/references/build.md` | reference (build) | Record the store's guarantees and the choices they drove | "Record it" | None. |
| `standards/persistence/references/review.md` | reference (review) | Calibration and severity | Severity levels | None. |
| `standards/security/SKILL.md` | standard plugin | Security rubric: taint model, foundations, OWASP A01–A10 | "Injected …"; install-name collision | Install-name fix only. |
| `standards/security/references/build.md` | reference (build) | Lock rule; record a missing SCA scanner (as a not-run `scan` step) and secrets to rotate | "Record it"; names a `scan` gate step | Check that the new build report still has a `scan` step, or rename it. |
| `standards/security/references/review.md` | reference (review) | Attack-scenario bar and severity | Severity levels | None. |
| `standards/self-documenting-code/SKILL.md` | standard plugin | Comments, docstrings and names as documentation | "Injected …"; install-name collision | Install-name fix only. |
| `standards/self-documenting-code/references/build.md` | reference (build) | Placement bar; record comments kept against a bar | "Record it"; mentions the commit and PR message | None. |
| `standards/self-documenting-code/references/review.md` | reference (review) | When to flag, and severity | Severity levels | None. |
| `standards/testing/SKILL.md` | standard plugin | Test rubric: tests that can fail, required tests, proven gaps, levels, mocks, goldens, isolation | Line 17: mutation runs "only as `references/test.md`'s Mutations sets". Line 47: the template "arrives in the tester's first message after `references/test.md`" (the old role order); "the test plan's `untested` list"; waiver "by the human's approval of the plan" (the old test-plan gate). Install-name collision. | Reword the line-47 delivery sentence to the test job's file order. Keep the plan and waiver wording if the new test flow keeps an approved plan. Install-name fix. |
| `standards/testing/references/test.md` | reference (test role) | Reporting and mutation rules for the tester | `standard-code-test-report` (plan contract, deltas, deviations). `standard-code-build-report` checked with `--kind test`. `mutation-copy.sh open` and `remove` (`procedure-seat-run/scripts/mutation/`). "Refused while it exists", which is the old stop hook `rules/stop/mutation-copy.sh`. The copy under `drafts/agents/<seat>/mutation/`. "Real worktree". `open` items. | The most coupled file. Repoint it to the new test report and plan owner, and to the new mutation-copy piece and its stop check, with a job-scoped path instead of a seat-scoped one. |
| `standards/testing/references/review.md` | reference (review) | Repair and clock calibration; severity | Severity levels | None. |
| `standards/testing/references/untested-template.md` | reference (template) | The JSON shape of one `untested` entry (`id` N-n, case, reason, risk, category, proof, recommend) | The template glob in `plugin-files.sh` (builder and tester only). The shape belongs to `standard-code-test-report`'s plan contract. | None, if the new test plan keeps the `untested` list. Otherwise its owner moves with that contract. |

## Install collision

The standard plugins' names collide with the old harness's installed skills. `~/.claude/skills/standard-testing`, `standard-security`, `standard-clean-code` and the others are symlinks into `ROOT/software-development/shared/standards/lens/`.

`list-plugins.sh` lists only folders with `disable-model-invocation: true`. Still, both sets cannot be installed under one skills folder with the same names. The accessibility, language, framework and procedure names are free today.

## Injection map (old rewrite, as it works today)

Every path below is under `ROOT/rewrite/domains/software-development/core/main-thread/flows/flow-code-agent-dispatch/` unless another root is named. "Decide" is the main-thread flow, not a separate init skill: `flow-code-agent-dispatch/SKILL.md`, loaded by `flow-code-build` and `flow-code-test`.

### Decide (main thread, flow steps 2–8)

1. **`scripts/dispatch-plan/list-plugins.sh`** scans `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/` for the four kind-prefixed folders. It applies the frontmatter test (name, `disable-model-invocation`, label, no base, a safe path) and the role-file rule. It prints one line per plugin: kind, name, label, description, `SKILL.md` path and role-file path.
2. **`scripts/dispatch-plan/installed-plugins.jq`** turns that listing into `{name: {kind, label}}`.
3. **Main picks plugins** by matching descriptions against what the task touches. `references/boundary-map.md` settles overlaps. One language; frameworks only with it; every installed standard and procedure gets `--load` or `--skip`.
4. **`scripts/dispatch-plan/generate-dispatch-plan.sh`** checks the picks with `dispatch-plan-validator.jq` and writes a `plan.made` event. The plan rules:
   - at most one language, and frameworks only with a language;
   - every standard and procedure is decided;
   - a reviewer plan holds one lens (tech, one standard, or none);
   - a builder or tester plan holds a language and at least one standard;
   - `standard-testing` goes into every tester plan and no other.
5. **`scripts/dispatch-plan/render-dispatch-plan.sh`** shows the plan card and builds the question. The human answers through `procedure-approval-gate`: `open-gate.sh`, then the gate hooks record a gate event.
6. **`scripts/agent-dispatch/generate-agent-dispatch.sh`** runs after approval, using `plugin-files.sh`, `agent-dispatch-validator.jq` and `dispatch-names.jq`. It:
   - needs the plan's sha256 and an approving gate event no more than 7 days old;
   - needs the seat open, with its mode and a worktree (`seats.sh get`);
   - cuts the context with `context.sh freeze --expect`, giving a `context.cut` event;
   - resolves the plugin files per role with `resolve_role_paths` (code-builder is builder, code-tester is tester, code-reviewer is reviewer);
   - writes a `dispatch.made` event: `{agent, seat, task, entry_points, context, plan, plugins:{language, frameworks, standards, procedures: {name, paths}}, continue_from, notes, test_plan}`;
   - prints `DISPATCH:`, `LABELS:`, `TITLE:` and `AGENT:`.

   A re-seat (`--reseat`) repeats the seat's last dispatch with `continue_from` and notes, and no gate.

### Enforce and inject (hook)

7. **`scripts/agent-prompt/prepare-agent-prompt.sh`** is a PreToolUse hook on `Agent`. The human registers it in `settings.json`; it is not installed by a script.
   - **Scope:** it acts only on `listed_agents`, which are code-builder and code-tester. code-reviewer is excluded because "no review seat exists". Every other agent passes untouched.
   - **Checks:**
     - the call runs in the background;
     - the prompt is exactly `DISPATCH: <path>`;
     - the event's shape is valid;
     - the pinned `context.cut` passes procedure-context's checks and is still the latest (except on a re-seat);
     - every plugin file is regular, inside its plugin folder, symlink-resolved, with SKILL.md first and contiguous, and passes the same frontmatter test;
     - the seat (`seats.sh get`) is open with a worktree, and its pair is not working or gave-up;
     - each skill the agent's `skills:` frontmatter preloads is installed.
   - **Message:** it copies every checked file into a temp snapshot, so the bytes it checked are the bytes it sends. It then builds the agent's first message from those copies:
     - `# Your plugins`: one `<crucible-plugin name="…">` block per plugin, frontmatter stripped, files in load order (language, frameworks, standards, procedures).
     - `# Your context`: the `context.cut` JSON.
     - `# Handling your context`: procedure-context's `references/agent-context-rules.md`.
     - `# Your work`: MODE (from the seat), TASK, WORKTREE (from the seat), ENTRY POINTS, REPORT (from `iteration.sh`, or PLAN for a tester), TEST PLAN, CONTEXT FILE, and on a re-seat CONTINUE FROM and NOTES.
   - **Output:** it returns `updatedInput` with the prompt replaced. It writes `dispatch.allowed {dispatch seq, tool_use_id}`, or on a deny `dispatch.denied` with KIND-tagged problems: DISPATCH, AGENT, CONTEXT, CONTEXT-STALE, PLUGIN, SEAT, PAIR, BACKGROUND, SKILL.
8. **`procedure-seat-run`'s `seat-bind-hook.sh`** (PostToolUse on `Agent`) reads `dispatch.allowed` by `tool_use_id` to bind the running agent to its seat.
9. **`scripts/dependencies/validate-dependencies.sh`** (flow step 1) fingerprints the `settings.json` hook entries: the inject hook, the gate question and answer hooks, seat bind, report commit, block relay, pre-tool write scope and events guard. It also checks tools.

### What the injection depends on

- **Install layout:** plugins live flat in `${CLAUDE_CONFIG_DIR}/skills/` under the kind-prefixed folder names. `--skills-dir` must be the default.
- **Seat machinery** (`procedure-seat-run`): `seats.sh` (status, mode, worktree, role, pair) and `iteration.sh` (the REPORT path); re-seat and handover; `test-plan.made` as the seat's newest.
- **Context** (`procedure-context`): `context.sh freeze`, `agent-context-rules.md`, `agent-context-file-checks.sh`, `context-versions.sh`, `agent-context-validator.jq` and `agent-context-url.jq`.
- **Gate:** `procedure-approval-gate`'s `open-gate.sh` and its gate events.
- **Events and space:** crucible's `events.sh`, `crucible-space.sh` and `prune.jq`.
- **Views:** human-view's `show.sh` and `render.sh`, plus this flow's `views/` (`denial.jq`, `dispatch-plan.jq`, `common.jq`, `lines.jq`, `install-check.jq`).
- **Agent bodies:** each agent's body expects `# Your plugins`, `# Your work` fields and `review.md` Severity.
- **Tools and environment:** jq 1.6+ (`--rawfile`), POSIX sh, awk, sha256sum or shasum, and `CLAUDE_CODE_SESSION_ID`.

### Parts that exist only because of seats

`seat` in the dispatch, plus everything the hook reads through the seat:

- **From `seats.sh`:** MODE, WORKTREE, the open check, the PAIR check and the role.
- **From `iteration.sh`:** the REPORT path.
- **Re-seat only:** `--reseat`, `continue_from` and `notes`.
- **Tester only:** the newest-`test-plan.made` check.

The exclusion of the reviewer from `listed_agents` is seat-driven too. The plugin parts carry over to the job model unchanged:

- listing;
- plan rules;
- role-to-files resolution, which becomes kind-to-files;
- file checks;
- snapshot;
- the `<crucible-plugin>` blocks.

## Short list

**Moves as is**
- All 5 language plugins' `review.md`, and all 4 framework plugins (SKILL.md, `build.md`, `review.md`), provided the new review report keeps the four severity levels and the framework-needs-language rule.
- These standards, each with its `build.md` and `review.md`: accessibility, clean-code, observability, performance, persistence, security (except the `scan`-step check below) and self-documenting-code. Same proviso on severity levels.
- `standards/testing/references/review.md` and `standards/testing/references/untested-template.md`, if the new test plan keeps the `untested` list.

**Moves with coupling fixes**
- **Language SKILL.md ×5:** the agent names `code-builder` and `code-tester` in each description.
- **`languages/shell/SKILL.md`:** "the first message names fewer platforms" (the hook-built first message).
- **Language `build.md` ×5:** the gate step keys `format`, `typecheck`, `lint`, `test` and `manual` belong to `standard-code-build-report`; match them to the new build report.
- **`standards/security/references/build.md`:** the `scan` gate step name.
- **`standards/testing/SKILL.md`:** "arrives in the tester's first message after `references/test.md`" (the role's file order), and the test-plan approval wording.
- **`standards/testing/references/test.md`:**
  - `standard-code-test-report` and `standard-code-build-report --kind test`;
  - `mutation-copy.sh open` and `remove`, and the stop-hook refusal;
  - the `drafts/agents/<seat>/mutation/` path, the "real worktree" and `open` items.
- **Every standard plugin:** the install-name collision with the old harness's `standard-*` skills in `~/.claude/skills`. The descriptions' "Injected into the agent's first message" needs a reword only if delivery changes.
- **All plugins (contract, not text):** the role-to-files rule (`references/build.md`, `test.md`, `review.md`, `*-template.md`) must be restated as job kind to files. That includes standard-testing's `test.md` as the test kind's required file, and read-trackers' empty `build.md` stub, which existed only for the old rule.

**Doesn't move**
- **`core/plugins/procedures/read-trackers/`** (SKILL.md, `references/build.md`, `scripts/read-link.sh`): superseded by new-rewrite's `trackers` skill, which reads issues at discovery into the context. It is also outside the owner's "tech, framework and standards" move list. Its Jira reading has no new-rewrite counterpart yet.
