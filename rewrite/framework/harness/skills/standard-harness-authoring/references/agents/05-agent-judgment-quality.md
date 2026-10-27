# agent-05 · Judgment quality (AJUDG)

Purpose: every claim the agent returns is backed by what it actually read, gaps are reported rather than papered over, and a verifier judges independently with a stated burden of proof.

**Applies when:** every agent file whose agent returns claims. AJUDG-09–AJUDG-13 for verifiers only; AJUDG-14 for an agent whose value is an independent attempt or a blind comparison; AJUDG-04 for agents that judge code. An orchestrator-only agent: AJUDG-16–AJUDG-18 only.
**MUST lint:** none.
**Terms.** See `README.md` (the agent's text, verifier). A rule stated in a preloaded skill counts.

**Levels.** Each item takes the level of the heading above it.

## Evidence

### MUST

- **AJUDG-01** · Does every claim the agent returns cite `path:line` (or the input's own locator)? · Check: read the ground rules and the output format. · Fix: add "Every claim cites `path:line`; if you can't point to a line, you don't know it — say so".
- **AJUDG-02** · Is an inference marked as one ("appears to …") and kept apart from what the agent read? · Check: read the ground rules. · Fix: add "Mark an inference as one: 'is' only for what you read".
- **AJUDG-03** · Does the text forbid describing output the agent didn't see or lines it didn't read? · Check: read the ground rules. · Fix: add "Never describe output you did not see; if a conclusion rests on lines you did not read, say so".
- **AJUDG-04** · For an agent that judges code: is a comment, name or docstring never evidence, only what runs? · Check: read the ground rules. · Fix: add "A comment is not evidence; only executable code is".
- **AJUDG-05** · Is an artifact handed over in prose (a diff, a prior answer, a partial file from a cut-off run, the producer's own evidence) re-derived from its source before it's relied on? A script-produced artifact (lint output, a diff file) is trusted by design. · Check: read how each input is used. · Fix: add "Re-derive <artifact> from <source>; treat what you were handed as a claim to check".

## Honesty and calibration

### SHOULD

- **AJUDG-06** · Is an honest gap allowed and preferred: "I couldn't determine X", `UNSURE` and `UNDECIDABLE` are valid answers, and a marked gap beats a papered-over one? · Check: read the edge cases and the output. · Fix: add the gap answer and the sentence that prefers it.
- **AJUDG-07** · When the agent rates confidence, is confidence kept separate from severity, and does any rating below high carry the exact question or check that would settle it? · Check: read the rating rules; N/A without a confidence rating. · Fix: add "Severity is not how sure you are; below high, write the question that would settle it".
- **AJUDG-08** · When the agent assigns a severity or score, is each level defined by evidence or impact, with no overlapping bands, and does a case between two levels take the lower one? · Check: read the rubric in the agent's text; N/A without one. · Fix: define each level by its evidence; remove overlaps; add the take-the-lower rule.

## Verifier stance and independence

### SHOULD

- **AJUDG-09** · Does the verifier state its default verdict and where the burden of proof sits ("a PASS needs evidence", "default to FALSE_POSITIVE")? · Check: read the role and process. · Fix: add the default and the burden.
- **AJUDG-10** · Does the verifier name the opposite failure: inventing a defense to kill a real finding, or doubt it can't ground in a line? · Check: read. · Fix: add "Don't invent a defense to kill a real finding; doubt you cannot ground in a line is not a refutation".
- **AJUDG-11** · Does the verifier judge the claim as written, never widened or softened, and rate the code rather than the claim? · Check: read. · Fix: add "Judge the claim as written; rate the code, not the claim".
- **AJUDG-12** · Does the verifier decide on what it read itself, without guessing what other voters will say? · Check: read. · Fix: add "Do not try to guess what the others will say".
- **AJUDG-13** · When parallel copies split the work by lens, does the body say the lens changes where effort goes, not the standard for a verdict? · Check: read; N/A when the agent has no lens input. · Fix: add "Your lens changes where you look, not the standard for a true positive".
- **AJUDG-14** · When the agent's value is an independent attempt or a blind comparison, does it read only the files its brief names and never try to infer who produced what? · Check: read. · Fix: add "Read nothing else; do not infer which producer made which output".

## Process

### SHOULD

- **AJUDG-15** · When the agent can check a concrete claim by running something within its tools and scope, does the body tell it to check rather than believe? · Check: read; N/A for an agent without such a tool. · Fix: add "Check <kind of claim> with <tool> before relying on it".
- **AJUDG-16** · Is the process written as ordered steps, in the order they run, each naming the tool and the check ("Read X, then Grep for Y")? Without numbered steps the agent skips or merges a step and nothing shows it. · Check: read the process; a step that refers back to a later one FAILs. · Fix: number the steps; name the tool in each.
- **AJUDG-17** · Is there an edge-case section, one line per case and what to do? Without it the agent improvises on a case its author already foresaw. · Check: read. · Fix: add the section.
- **AJUDG-18** · Is there a self-check that runs last, before replying: one per mode, or one naming every mode it covers? Without a last check, a reply with a missing item line or a verdict that contradicts its statuses goes out unseen. · Check: read; a self-check inside the process counts when it runs last. · Fix: add the self-check.
