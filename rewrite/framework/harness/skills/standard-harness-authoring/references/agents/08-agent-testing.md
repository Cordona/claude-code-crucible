# agent-08 · Testing (ATEST)

Purpose: the agent has been run on the cases that break agents before anyone relies on it, and the runs are on record.

**Applies when:** every agent file, before first use and after a substantive change to its body or frontmatter. ATEST-07–ATEST-09 for routed agents only; ATEST-10 for routed agents shipped in a plugin. An orchestrator-only agent: ATEST-01–ATEST-04.
**MUST lint:** none.
**Terms.** See `README.md` (routed agent). **On record:** the run's output and grade, with its input, are among the run outputs and grades the flow passes in. Every Check below reads them.

**Levels.** Each item takes the level of the heading above it.

## SHOULD

- **ATEST-01** · Was the agent seen loading, by a dispatch that reached it? A file with a bad name or broken YAML is skipped silently. · Check: a run is on record. · Fix: dispatch it once and put the run on record.
- **ATEST-02** · Was it run on a typical task from one of its dispatching flows? · Check: the run is on record. · Fix: run it and put the run on record.
- **ATEST-03** · Was it run on one edge case its body names? · Check: the run is on record and names the case. · Fix: run it and put the run on record.
- **ATEST-04** · Was it run on a malformed dispatch, and did it stop and name the input (ADISP-13)? · Check: the run is on record with the refusal it returned. · Fix: run it and put the run on record.
- **ATEST-05** · Was it run on an input with nothing to find, and did it return the "nothing found" answer, not padding (AOUT-09)? · Check: the run is on record. · Fix: run it and put the run on record.
- **ATEST-06** · Was one run's reply checked with the caller's parser or schema? · Check: the run is on record with the check's result. · Fix: run the caller's parser on a reply.
- **ATEST-07** · Was routing tested with realistic phrasings of each trigger situation, none naming the agent? · Check: the phrasings and which agent ran are on record. · Fix: run 3 or more phrasings per situation and put them on record.
- **ATEST-08** · Was over-triggering tested with near-miss requests the agent should not take? · Check: the near-misses and results are on record. · Fix: run them; tighten the not-for line (ADISP-07) on a false trigger.
- **ATEST-09** · Was a request that an agent with an overlapping role could also take tested, recording which agent won? · Check: the run is on record. · Fix: run it; sharpen the description (ADISP-04) if the wrong agent wins.
- **ATEST-10** · Was delegation measured with `claude plugin eval`, with and without the plugin? · Check: the eval result is on record. · Fix: run the eval and put its result on record.
