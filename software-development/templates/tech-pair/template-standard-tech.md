<!--
TEMPLATE — never deployed (the Crucible Management Hub's discovery logic (deploy/hub/lib/hub-discovery.sh)
excludes any `template-*`-named file by an explicit name-prefix check; living under `templates/`
additionally keeps it out of scope structurally, since that directory is never passed to discovery as a
scan root — but that is not itself an executed check, so never rely on directory location alone).

Extracted from standard-kotlin/SKILL.md, standard-rust/SKILL.md, and standard-shell-script/SKILL.md.
This is the SHARED rubric both the new {{tech}}-developer and {{tech}}-reviewer bind to — it is
the single most consequential artifact this whole generation flow produces, since a shallow or
wrong entry here corrupts both agents at once, permanently, until someone notices. It should be
authored from the research swarm's synthesis, not free-invented.

Lives at: software-development/shared/standards/tech/standard-{{tech}}/SKILL.md

Tokens: {{tech}}, {{Tech}} — same as the other two templates.
-->
---
name: standard-{{tech}}
description: The single definition of idiomatic, correct {{Tech}} — the shared language rubric that the {{tech}}-developer BUILDS to and the {{tech}}-reviewer REVIEWS against. Applies whenever {{Tech}} code is written, changed, or reviewed (<!-- FILL: 3-6 comma-separated real contexts, e.g. frameworks/runtimes/deployment shapes -->). Defines <!-- FILL: the same idiom-area list used in both agent files (no fixed count — the deployed roster currently spans roughly 9-13 titled sections; read 2-3 to calibrate, don't target a number) — this description line and the two agent files' "defined in standard-{{tech}}" sentences must stay in sync -->. This is WHAT good {{Tech}} looks like; it does not define builder workflow (build-core), the reviewer's own correctness-detective method / scope-boundary / category vocabulary (the {{tech}}-reviewer), its handoff pattern / severity philosophy (review-core), or the build/report envelopes (build-report-standards / review-report-standards).
---

# Standard: {{Tech}}

The **one** definition of what good, correct {{Tech}} looks like. The `{{tech}}-developer` builds to it; the `{{tech}}-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we write {{Tech}} and how we review it — a rule changed here moves both sides at once.

This skill defines **WHAT good looks like** — the idioms to reach for and the traps to avoid. It is **NOT a {{Tech}} tutorial**: assume fluent {{Tech}}, and encode only the non-default priorities and easy-to-miss pitfalls. It deliberately does NOT contain: the builder's workflow (`build-core`); the reviewer's own machinery — the correctness-detective method, scope-boundary, and `category` vocabulary — which live with the `{{tech}}-reviewer`; its handoff pattern and severity philosophy, which live with `review-core`; or report envelopes, which live in `build-report-standards` / `review-report-standards`.

<!-- FILL: if this language has a single frozen default worth freezing (most do), state it here: "Assume **X** unless the project states otherwise." Only if the language genuinely has no such default (e.g. a fast-moving edition/toolchain choice — see standard-rust's precedent, which states none) — omit this line entirely and let template-tech-developer.md's own FILL instructions (its "version/toolchain default clause") own the concrete value instead, per that template's own escape-hatch branch. -->

<!--
FILL: the body below is the actual research payload. Most existing standard files have roughly 9 to
13 titled sections (## headings) — re-check `shared/standards/tech/*/SKILL.md` at generation time
rather than trusting this number (one deployed standard uses a deliberately different 3-pillar
structure for its own domain reasons; that is an exception to imitate only if your language has a
comparably different shape, not a second data point for the normal range). Roughly this shape:

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
