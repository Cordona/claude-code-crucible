# Waivers: procedure-agent-initialization

- HK-11: no test script; the owner's rule is no tests for these scripts, and every allow and deny path was live-validated (scripts/inject-plugins-r1.md, -r2.md, live/e2e.md) (owner)
- SCR-04: no size cap; a hook decision can't be truncated, and the injected size is bounded by the installed plugins (about 105 KB for one tech plugin plus all seven standards, delivered verbatim in the probe) (owner)
- DET-04: no plan-status state file; the only file the procedure writes is the gate's transient plan file (render input, removed with its gate), and every approval is an AskUserQuestion answer visible in the conversation (owner)
- DET-06: no persisted step/state file; the plan file is render input, not state (as DET-04), and the Resume section re-runs steps 1-2 and re-asks every plan whose approval is not visible (owner)
- SCH-15: no rejection log by design; the only file written is the gate's transient plan file, and render-dispatch-plan.sh reports each input problem on stderr (owner)
- LNT-15: body 5,080 tokens, a known overrun; slimming is a follow-up (owner)
