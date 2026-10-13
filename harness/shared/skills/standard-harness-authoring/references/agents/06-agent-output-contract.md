# agent-06 · Output contract (AOUT)

Purpose: the agent returns exactly what its caller parses, a cut-off or failed run never looks like a finished one, and nothing unchecked reads as clean.

**Applies when:** every agent that is dispatched (N/A for an orchestrator-only agent). AOUT-15 only for an agent that writes a deliverable people read.
**MUST lint:** none.
**Terms.** See `README.md` (the agent's text, dispatching flow). How the caller screens and re-runs a reply is judged in 06.

## Shape

- **AOUT-01** · MUST · Does the agent's text define one fixed return shape: a structured object, fixed sections, or fixed lines? · Check: read the output section. · Fix: write the shape out, field by field.
- **AOUT-02** · MUST · Does that shape match what each dispatching flow parses (its schema, script or brief), field by field? · Check: read the output section against each caller's parser or schema. · Fix: align the field names and order with the caller.
- **AOUT-03** · MUST · Is the whole shape stated in the agent's text or in a contract it cites, not only in a workflow schema or command file the agent never reads? · Check: find where each returned field is defined. · Fix: describe the field in the output section, or cite the contract by path.
- **AOUT-04** · MUST · Does the reply carry no preamble or narration around the shape? · Check: read the output section. · Fix: add "Return exactly <shape>: no preamble, no narration".
- **AOUT-05** · SHOULD · Does the output section say what reads the reply: a script, a flow step, or a person? · Check: read. · Fix: add "Your reply goes to <reader>".
- **AOUT-06** · SHOULD · Is the return compact? Every return lands in the caller's context; detail beyond it goes to a file the reply names. · Check: read the output section; an unbounded free-text section FAILs. · Fix: move detail to a file; cap the reply.
- **AOUT-07** · MUST · When the output runs past about 200 lines, or goes to a file a script checks, does it end with a fixed end line (`=== END OF <ID> ===`)? · Check: read the output section. · Fix: add the end line as the last line of the shape.
- **AOUT-08** · SHOULD · When the agent writes a long answer to a file, does it write its plan and partial results early and keep the file current, so a cut-off run leaves something usable? · Check: read the steps; N/A without a file output. · Fix: add "Write your plan to the file first, then each result as you reach it".
- **AOUT-09** · MUST · Is "nothing found" a valid answer, and padding never one? · Check: read the output section and edge cases. · Fix: add the empty answer to the shape, and "a padded or invented item costs more than a missed one".
- **AOUT-10** · MUST · Does the shape have an explicit value for "could not do the job" (a refusal line, `UNSURE`, `not cleaned: <file>`), so failure never looks like an empty success? · Check: read the shape. · Fix: add the failure value and when to use it.
- **AOUT-11** · MUST · Does the output tell "checked and clean" apart from "not checked"? A tool that is missing or didn't run, a skipped directory, or a build that didn't run is reported as such. · Check: read the shape and edge cases; N/A when the agent runs no tools and skips nothing. · Fix: add a coverage field ("ran / not run: <reason>").
- **AOUT-12** · MUST · Does the agent leave counting across agents to code? It returns per-item judgments; a verdict over its own items only is allowed, never a tally or verdict across agents. · Check: read the output section. · Fix: remove the tally; return per-item lines.
- **AOUT-13** · SHOULD · Do contract-constrained values the agent emits (finding categories, ID prefixes, severity enums) come from that contract, cited or generated, not copied into the body? · Check: compare the body's lists with the contract (e.g. `x-reviewers` in `review-category.schema.json`). · Fix: cite the contract or generate the list from it.
- **AOUT-14** · MUST · Does the reply avoid text shaped like a system tag (`<system-reminder>`) or a `Human:` / `Assistant:` turn? The output scanner escapes such text, which changes the bytes the caller parses. · Check: read the shape and any quoted examples it returns. · Fix: rename the tag or quote it inside a code span; an agent that relays found text carries the canonical quote-safely line (agent-07, Canonical blocks; LNT-60).
- **AOUT-15** · SHOULD · Does a deliverable for people stand alone, with no references to run files ("see `r3_q4.answer.md`")? · Check: read the deliverable rules. · Fix: add "Inline what you cite; never point to run files".
