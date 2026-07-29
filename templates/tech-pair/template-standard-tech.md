<!--
TEMPLATE — never deployed (deploy.sh excludes anything template-prefixed or under templates/,
by two independent checks — never rely on directory location alone).

Extracted from standard-kotlin/SKILL.md, standard-rust/SKILL.md, and standard-shell-script/SKILL.md.
This is the SHARED rubric both the new {{tech}}-developer and {{tech}}-reviewer bind to — it is
the single most consequential artifact this whole generation flow produces, since a shallow or
wrong entry here corrupts both agents at once, permanently, until someone notices. It should be
authored from the research swarm's synthesis, not free-invented.

Lives at: roles/common/skills/standards/tech/standard-{{tech}}/SKILL.md

Tokens: {{tech}}, {{Tech}} — same as the other two templates.
-->
---
name: standard-{{tech}}
description: The single definition of idiomatic, correct {{Tech}} — the shared language rubric that the {{tech}}-developer BUILDS to and the {{tech}}-reviewer REVIEWS against. Applies whenever {{Tech}} code is written, changed, or reviewed (<!-- FILL: 3-6 comma-separated real contexts, e.g. frameworks/runtimes/deployment shapes -->). Defines <!-- FILL: the same idiom-area list used in both agent files (no fixed count — match genuine distinct idiom areas, Kotlin's real standard has 9, Rust's has 12) — this description line and the two agent files' "defined in standard-{{tech}}" sentences must stay in sync -->. This is WHAT good {{Tech}} looks like; it does not define builder workflow (build-core), the reviewer's correctness-detective method / scope-boundary / severity / category vocabulary (the {{tech}}-reviewer), or the build/report envelopes (build-report-standards / review-report-standards).
---

# Standard: {{Tech}}

The **one** definition of what good, correct {{Tech}} looks like. The `{{tech}}-developer` builds to it; the `{{tech}}-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we write {{Tech}} and how we review it — a rule changed here moves both sides at once.

This skill defines **WHAT good looks like** — the idioms to reach for and the traps to avoid. It is **NOT a {{Tech}} tutorial**: assume fluent {{Tech}}, and encode only the non-default priorities and easy-to-miss pitfalls. It deliberately does NOT contain: the builder's workflow (`build-core`) or the reviewer's machinery — the correctness-detective method, scope-boundary/handoff, severity, and `category` vocabulary live with the `{{tech}}-reviewer`; report envelopes live in `build-report-standards` / `review-report-standards`.

Assume **<!-- FILL: the default version/toolchain/edition -->** unless the project states otherwise.

<!--
FILL: the body below is the actual research payload. Each existing standard file has somewhere
between 8 and 14 titled sections (## headings), roughly this shape:

  - The language's #1 correctness/safety surface (Kotlin: null safety; Rust: ownership &
    borrowing; Shell: quoting & expansion) — always comes first, always the deepest section.
  - Data modeling / type-system idioms.
  - Concurrency/async model, IF the language has one worth a dedicated section.
  - A "silent traps" or "the traps that don't look like traps" section — the pitfalls that
    compile/run fine but are wrong (Kotlin: copy()/init{} interaction; Rust: std trait contracts;
    Shell: exit-status masking, subshell scope loss).
  - Naming / idiomatic-construct conventions.
  - Micro-performance / allocation hygiene (language-level only — algorithmic complexity is
    lens-performance's job, not this file's).
  - Framework-specific notes, IF a specific framework was named during the research/poll step.
  - Lint/format/static-analysis discipline and the "clean" bar.

  Do NOT pad to hit a section count, and do NOT skip the language's genuinely highest-risk area
  to save space — match depth to actual risk, the way Rust's standard gives "Unsafe" and "Async
  Hazards" their own sections because that's where Rust code actually breaks.

  Ground every section in the research swarm's synthesis (the style-guide angle, the pitfalls/
  postmortems angle, the linter-rules angle, and the framework-conventions angle if applicable) —
  this file is supposed to be the CODIFICATION of that research, not a paraphrase of general
  knowledge about the language.
-->

## <!-- FILL: section 1 title -->

<!-- FILL -->

---
*Standard Version: 1.0 — the shared {{Tech}} rubric. Built to by the {{tech}}-developer (via build-core); reviewed against by the {{tech}}-reviewer.*
