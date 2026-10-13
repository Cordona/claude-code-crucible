# 11 · Schemas and generated JSON (SCH)

Purpose: JSON contracts keep a flow deterministic while agents read and write as few tokens as the contract allows, and no agent writes a payload worse because it saw less.
Judges who writes and reads each field, what agents are shown and return, and where each rule lives. Marker presence, schema paths in agent text, card existence, freshness, size and stability, description length and caps are lint.

**Applies when:** the skill, or an agent it dispatches, writes or reads JSON against a contract (`contracts/*.schema.json` or a skill-local schema).
**MUST lint:** LNT-52, LNT-53, LNT-54, LNT-57.
**Overlaps:** WF-03 (validate loops), SUB-07 (seat return contracts) and DET-01 (script what must be deterministic) stay the general rules. This checklist judges only their JSON-contract case, including revisions the orchestrator makes. One problem fails once, here.
**Unmarked contracts:** while LNT-52 FAILs, treat every unmarked field as agent-written for LNT-57 and SCH-14, and report SCH-08 and LNT-54 as `UNDECIDABLE (blocked by LNT-52)`. A missing card (SCH-08) makes SCH-09 and SCH-10 `N/A (no card, SCH-08)`.

**Terms.**
- **Contract:** the strict schema plus the validator script that enforces it (for example a jq library). Between them they hold every rule.
- **Payload object:** each schema root, and each object a script stores as its own file (a sidecar).
- **Writer:** whoever supplies a field's value: `script`, `orchestrator`, or `agent:<name>`.
- **Agent card:** a Markdown file generated from the contract for ONE writing agent, at `contracts/cards/<contract>.<agent>.md`. It holds only what that agent needs, and is never written by hand.
- **Reader:** a script, render, agent or gate decision whose output or choice changes with the field's value. Validating a field, carrying it through unchanged, or an agent re-reading the whole payload does not make a reader.

## Who writes, who reads

- **SCH-01** · MUST · Does every first-level `properties` entry of a payload object carry `x-writer` naming every party that may set or change its value (`script`, `orchestrator`, `agent:<name>`, or a list)? Nested fields inherit unless they carry their own, and `$defs` are exempt. A list naming three parties on most fields is itself a sign the payload is rewritten too often (SCH-04). · Check: lint LNT-52; judge beyond it that the marker matches who actually writes the field, including a second agent that rewrites it. · Fix: add or correct the marker.
- **SCH-02** · MUST · Does every field have a reader (Terms)? · Check: grep the scripts, the renderer and the consuming agents' briefs for the field name, and confirm a use that changes with the value. · Fix: drop the field; or, for a provenance or audit field, name its later reader and use in a waiver.
- **SCH-03** · MUST · Does an agent write only what it alone can know? It never supplies a value a script can derive from inputs the script already has: timestamps, sequence numbers, counts, verdicts, status, or a list copied whole from the diff (writing a selected subset is fine). No two agent-written fields carry the same information. Ids the agent defines and cross-references inside the payload (a behavior `B1` that a test's `guards` names) are fine. · Check: read the agent-written fields against the writer scripts' inputs. · Fix: move the field to the script, or merge the duplicates.
- **SCH-04** · MUST · Does any agent, or the orchestrator, that reviews or revises a payload return only its decisions or a patch (added items in full, unchanged items never), with a script merging it and then validating the whole? · Check: read each reviser's return shape and the merge step; compare a draft with its revised copy for byte-identical sections. · Fix: give the reviser a decisions-or-patch shape; add a merge script.

## Where rules live

- **SCH-05** · MUST · Is every mechanically checkable rule about a payload field enforced by the contract, never only stated in prose? Judgment rules (is a reason genuine, is a test meaningful) stay with the reviewing agent and are exempt. · Check: read the payload rules in the card and in the writing and reviewing agents' bodies; for each checkable one, find the schema keyword or validator line. · Fix: add the check to the validator, or move the rule to the reviewing agent as judgment.
- **SCH-06** · MUST · Does every rule (cap, enum, pattern, required field) have one source? The schema is that source and the card is generated from it. The validator reads its constants from the schema; only when it cannot read the schema at run time does an agreement check assert they match. No agent body restates a cap or enum. · Check: compare the schema's caps and enums with the validator's constants and with the agent bodies. · Fix: have the validator read the schema (an agreement check only under the condition above); replace restated caps with the card.

## What agents see

- **SCH-07** · MUST · Do agents see only their agent card, never the full contract or a file only the validator reads (word lists, lookup tables)? · Check: lint LNT-53. · Fix: replace the path with the card's path, or inline the card in the brief.
- **SCH-08** · MUST · Does every agent named in an `x-writer` marker have its own card, generated from the contract by a script and identical to a fresh run? · Check: lint LNT-54. · Fix: build the generator; generate the card; delete any hand-written copy.
- **SCH-09** · MUST · Is the card enough to write a valid payload the first time? It lists every field this agent writes, with type, required or optional, the meaning of null or empty, allowed values and length caps, and a one-line meaning. It lists the cross-field rules in one line each, names the fields the agent must leave out, gives one real example that passes the validator's shape checks, and gives the write-and-validate command. · Check: read the card against the contract's fields for that agent; run the example through the shape checks (diff-scope and repo-path checks are skipped). · Fix: add the missing field facts; replace an example that fails.
- **SCH-10** · SHOULD · Is the card within budget and stable? At most 8,000 characters (about 2,000 tokens), example included. Byte-identical across runs (sorted, no dates or machine paths), so it caches in prompts. · Check: lint LNT-55 and LNT-58. · Fix: shorten meanings to one line; trim the example to one item per list; drop varying content from the generator.
- **SCH-11** · MUST · Does every validator rejection name the field path, the problem, and what was expected (for an unknown field, the allowed keys), so a rejected write costs one retry, not a search? · Check: read every error path in the validator. · Fix: `<field path>: <problem>; expected <x>`.
- **SCH-12** · SHOULD · Does a consumer get only what it needs? The human sees the rendered summary, never raw JSON. An agent consuming a payload gets the payload plus its card when it must interpret fields, never the contract. A payload over 8,000 characters that an agent reads in more than one round is distilled by a script to the parts that round needs. Exposure to the contract itself is SCH-07. · Check: read every dispatch brief and step that hands over a payload; measure the payloads handed over. · Fix: hand over the render, the card or a script's distilled output.

## Lean contracts

- **SCH-13** · SHOULD · Are schema descriptions one line about what the field means, with no script names, history or rationale, and are shared definitions referenced with `$ref`, never copied? · Check: lint LNT-56; judge beyond it whether a short description still carries script internals, and whether near-identical patterns differ only by accident. · Fix: cut the explanation; hoist repeated text and patterns into one `$defs` entry.
- **SCH-14** · MUST · Does every agent-written string and array have an effective cap (`maxLength` / `maxItems` after resolving `$ref` and `allOf`; an `enum`, `const` or fixed-length `pattern` counts), sized to real use? · Check: lint LNT-57; judge beyond it whether the caps fit measured payloads. · Fix: add caps sized from a measured payload (SCH-15).

## Evidence

- **SCH-15** · SHOULD · Is the contract sized from real use? The writer scripts append each rejection (field path and rule) to a log; a rule rejected again and again goes into the card as one line. · Check: read the log; a missing log is a FAIL. · Fix: add the rejection log.
- **SCH-16** · SHOULD · Does a stored payload that was valid when written, especially an approved one, stay readable after the contract tightens? Write-only rules apply on write; read paths check shape, not new caps; a `schema_version` change comes with a migration or a stated cut-over. · Check: read the validator's read paths and its `schema_version` handling. · Fix: mark the new rule write-only, or ship a migration.
- **SCH-17** · SHOULD · Where the harness can tell a subagent from the main session, does a hook block subagent reads of the contract set, so SCH-07 holds even when a path leaks? · Check: read the declared hooks. · Fix: add a PreToolUse hook on Read that exits 2 for a subagent reading the contract set.
