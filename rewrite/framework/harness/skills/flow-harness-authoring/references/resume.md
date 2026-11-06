# Resume

How a cut-off run continues, read after a compaction, an interruption or a new session, before any other step.

1. Read `<run dir>/state.md`; ask the human for the run dir if the conversation no longer names it.
2. Check that the target and every run file it names exist and match it; a mismatch fails closed (`SKILL.md` Always).
3. Skip the steps it marks done, keep its run inputs and counters, and continue from its current step.
4. A gate that was open: start it again from `SKILL.md` Gates step 1; never relay a view from memory.
