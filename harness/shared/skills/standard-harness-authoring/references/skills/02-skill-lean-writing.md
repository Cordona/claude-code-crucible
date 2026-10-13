# 02 · Lean writing (LEAN)

Purpose: every token earns its recurring context cost, without losing a rule or the reason that protects it.
Judges what is said and how; emphasis density, time-sensitive phrases and sentence length are lint.

**Applies when:** every skill, command and agent body, and their reference files.
**MUST lint:** none. SHOULD lint used here: LNT-23, LNT-24, LNT-70.
**Protection rule:** the lean-pass invariant in `SKILL.md` (Invariants) applies; after the lean pass, re-run 04, 05 and 09.

- **LEAN-01** · SHOULD · Would the agent get each paragraph wrong without it? · Check: strike only paragraphs that define a term found in standard language/tool docs, restate basics, or give generic advice; protected text (above) is never struck. · Fix: delete the struck paragraph; keep protective rationale as one sentence or a code comment.
- **LEAN-02** · SHOULD · Is each rule grounded — it names a project path, contract or decision, or corrects a model failure that the skill names? · Check: yes if every rule meets one of the two; an unnamed failure counts as generic. · Fix: replace the generic rule with the concrete fact, name the failure it corrects, or cut it.
- **LEAN-03** · SHOULD · Are instructions direct imperatives with at most one sentence of reason in the body, no first person, and "you" only for role framing (an agent body addressing its own agent is role framing)? · Check: yes if any longer rationale sits in a code comment. · Fix: lead with the action; cut the reason to one sentence, keeping any protective reason.
- **LEAN-04** · SHOULD · Is emphasis (caps, MUST, NEVER) placed only on rules whose single violation is costly, each with its reason? · Check: judge placement only; density is LNT-23. · Fix: drop caps from ordinary rules; add the reason to those that stay.
- **LEAN-05** · SHOULD · Is the guidance a reusable procedure at moderate detail, leaving non-fragile edge cases (WF-05's test) to judgment? · Check: past cases are allowed when labelled as calibration with their class; unlabelled one-off answers are no. · Fix: generalize to the category, or label the example as calibration.
- **LEAN-06** · SHOULD · Does each choice point (alternatives for the same action) give one default and its escape hatch? · Check: lists of distinct required items are not choice points. · Fix: name the default and the one condition that switches.
- **LEAN-07** · SHOULD · Is one term used per concept, matching the skills it cites, with concrete examples (real paths, values)? · Check: list synonyms of the key nouns. · Context: the cited skills, for the terms the target uses. · Fix: pick one term and replace the synonyms; swap abstract examples for real ones.
- **LEAN-08** · SHOULD · Is the text free of claims that drift — dates, `currently`-style words, self-measured counts — with version-sensitive facts in one dated place? · Check: judge only what LNT-24 cannot see (self-measured counts, version claims). · Fix: delete the drifting claim; move version pins to one table with last-verified.
- **LEAN-09** · SHOULD · Is the text scannable — one rule per bullet, no empty or duplicate sections, environment-specific corrections in one Gotchas/Edge-cases section? · Check: yes if no bullet carries two rules; sentence length is LNT-70. · Fix: split bullets; delete empty sections; merging or renumbering sections updates every citer (LNT-46).
