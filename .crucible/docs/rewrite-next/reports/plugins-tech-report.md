# Tech plugins brought into new-rewrite: report

The 9 tech plugins were copied from `rewrite/domains/software-development/plugins/tech/` to `new-rewrite/domains/software-development/plugins/tech/`, same layout, then aligned. `rewrite/` is untouched. Nothing committed. The know-how is unchanged: no old machinery (seats, flows, procedures, report skills, finding IDs, report fields, `§N`) was present in any of them, so the changes are only to references.

Edits common to several plugins:
- Headings `## <X> mechanisms for the shared standards` became `## <X> mechanisms` (kotlin, php, rust, typescript, laravel, nextjs, react, spring). "The shared standards" assumes the reader knows the standard plugins. Each bullet already names its concern (Queries, Logging, Supply chain…).

## Per plugin

**kotlin.** Removed: `(code-builder, code-tester, standard plugins)` from the description, and the "shared standards" heading wording. Unsure: nothing.

**php.** Removed: `framework-laravel` and `(code-builder, code-tester, standard plugins)` from the description, and the heading wording. Unsure: `review.md` says "the builder's format step covers it". It names a role, not a file, so I kept it.

**rust.** Removed: `(code-builder, code-tester, standard plugins)` from the description, and the heading wording. Unsure: nothing.

**shell.** Removed: `(code-builder, code-tester, standard plugins)` from the description. "the first message names fewer platforms" (two places) became "the task names fewer platforms", to match the agents' "your prompt gives you the job". Unsure: whether "the task" is the right word for what the dispatch hands over.

**typescript.** Removed: `(code-builder, code-tester, standard plugins)` from the description, and the heading wording. Kept "(framework plugins)" in the description because it is generic and names no skill. Unsure: nothing.

**laravel.** Removed: `language-php` from the description, "against `SKILL.md`'s Output and queries section" from `review.md` (the CRITICAL line stands without it), and the heading wording. Unsure: nothing.

**nextjs.** Removed: `framework-react` and `language-typescript` from the description ("normally beside `framework-react`" became "normally beside React's"), and the heading wording. Unsure: nothing.

**react.** Removed: `standard-accessibility`, `framework-nextjs` and `language-typescript` from the description, "as the language plugin covers them" from Scope, and "runs in the language plugin's lint" (now "runs in the project's lint"), plus the heading wording. Unsure: nothing.

**spring.** Removed: `language-kotlin` from the description, and the heading wording. Unsure: nothing.

## Overall

**References I kept, and why:**
- **Gate names in `build.md`** (`gate format`, `typecheck`, `lint`, `test`, `manual`). These are values from the closed list in `builder-common.jq` / `tester-common.jq`. `code-builder.md` doesn't list them, so without these names the builder would guess, and the stop check would refuse the guess. This is the one spot where a plugin touches a report value. Owner: should the agent definition list the gate names instead, so the plugins can drop them?
- **Cross-references inside a plugin.** `references/*.md` point at sections of the plugin's own `SKILL.md` without naming the file: "the Queries mechanism", "Toolchain step 5", "the `unsafe` rules", "the Zod rules", "Strict typing and modern idioms". I treated one plugin (its SKILL.md plus its references) as one piece. That only holds if the dispatch always injects `SKILL.md` together with the role reference. This needs confirming once the dispatch exists. If it doesn't, these lines have to say the rule themselves.
- **Framework to language order.** Frameworks say "settle it after PHP's/TypeScript's/Kotlin's toolchain", and the descriptions say "beside its language plugin". This is a loading dependency, not a reference to a file. A framework plugin is meant to run on top of its language plugin.
- **Severity levels in `review.md`.** These are kept as know-how (which defect is how serious). Their levels match the reviewer's `critical/high/medium/low`. They describe no format.

**The tester question (for the owner).** No tester reference was invented. The tester would clearly need something for these:
- **kotlin:** JUnit 5 / kotest idioms, `kotlinx-coroutines-test` (`runTest`, virtual time), and how to run a filtered test (`./gradlew test --tests '…'`, `-Dtest=` for Maven).
- **php:** PHPUnit vs Pest, and running one test (`--filter`).
- **rust:** `#[test]` / `#[tokio::test]`, integration tests in `tests/`, and `cargo test <name>`.
- **shell:** bats (or the project's harness), how to sandbox a script's writes during a test, and running one bats test (`--filter`).
- **typescript:** Vitest/Jest detection, running one test (`-t`, or the file path), and fake timers.
- **react:** Testing Library queries by role and `user-event` over `fireEvent`, plus async `findBy`.
- **nextjs:** how to test Server Actions and route handlers end to end (Playwright vs calling the handler).
- **spring:** `@SpringBootTest` vs slice tests (`@WebMvcTest`, `@DataJpaTest`), Testcontainers, and MockMvc.
- **laravel:** feature tests (`RefreshDatabase`, `actingAs`, the HTTP test helpers) and `php artisan test --filter`.

Also, all build gates use "existing tests (gate `test`)". The mutation gate the tester must report has no per-language guidance anywhere (for example `cargo-mutants`, Infection, Stryker, PIT).
