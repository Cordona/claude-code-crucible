# agent-04 · Dispatch contract (ADISP)

Purpose: the right caller picks the agent for the right request, and the agent accepts exactly the inputs its callers send, refusing anything else.

**Applies when:** every agent file. ADISP-01–ADISP-03 for dispatch-only and selected agents; ADISP-04–ADISP-08 for routed agents; ADISP-10 for orchestrator-only agents; ADISP-11–ADISP-15 for every agent that is dispatched.
**SHOULD lint used here:** LNT-67. The collection total (LNT-65) is a collection item (lint spec, Scope), not this seat's.
**Terms.** See `README.md` (dispatch-only, selected, routed and orchestrator-only agent; dispatching flow).

## Description

- **ADISP-01** · SHOULD · Is a dispatch-only or selected agent's description one sentence, "<role> dispatched by `<flow>` to <job>; not for direct invocation", with nothing else in it (no trigger list, no brief list)? · Check: read the description. · Fix: rewrite it as that sentence; move the brief list to Your dispatch.
- **ADISP-02** · SHOULD · Does a selected agent's description name its key ("selected by stack", "selected by lens")? · Check: read the description. · Fix: add the key.
- **ADISP-03** · SHOULD · Does the flow named in the description exist and dispatch this agent? · Check: grep the named flow for the agent's name. · Fix: correct the flow name, or remove an agent no flow dispatches.
- **ADISP-04** · SHOULD · Is a routed agent's description specific enough to single it out from agents with overlapping roles? · Check: read the descriptions of agents with a similar role; name one request each would win. · Fix: add the distinguishing job or input.
- **ADISP-05** · SHOULD · Does a routed agent's description name 2–4 trigger situations, covering both an explicit request and a state where the agent applies without being named? · Check: count the situations. · Fix: add or merge situations to reach 2–4.
- **ADISP-06** · SHOULD · Are the triggers written as situations, not as quoted user/assistant transcripts? `<example>` blocks are not required. · Check: read the description. · Fix: rewrite each transcript as one situation line.
- **ADISP-07** · SHOULD · Does a routed agent's description say when not to use it ("Not for …")? · Check: read the description. · Fix: add the not-for line, naming the agent to use instead.
- **ADISP-08** · SHOULD · Are a routed agent's triggers in the description itself, not only in a body section? The router never reads the body. · Check: read the description and grep the body for "When to invoke". · Fix: move the triggers into the description.
- **ADISP-09** · SHOULD · Does the description carry only what its reader (the router or the dispatcher) needs? · Check: its length is lint LNT-67 and the collection total LNT-65; judge only the content. · Fix: cut text the reader doesn't use; move it to the body.
- **ADISP-10** · SHOULD · Does an orchestrator-only agent's description say it runs only as the main session and is never dispatched as a subagent? · Check: read the description. · Fix: add "For use only as the main agent of a session; never dispatch it as a subagent".

## Your dispatch

- **ADISP-11** · MUST · Does a "Your dispatch" section list every input, each under the label or field name its callers use (`TARGET`, `MODE`, the brief's field name)? · Check: read the section; with no section, use the description's brief list for ADISP-12. · Fix: add the section, one line per input.
- **ADISP-12** · MUST · Does that list match every dispatching flow's brief, field by field? Nothing a flow sends is missing, and nothing the body relies on ("the tools provided in your prompt") is sent by no flow. · Check: grep each dispatching flow and compare its brief with the list; drift FAILs. · Fix: align the list, or add the missing field to the flow's brief (06).
- **ADISP-13** · MUST · Does a missing or malformed input (an unknown mode, a path that doesn't resolve, an empty required field) make the agent stop and say which (fail closed)? An agent only ever dispatched behind a validating dispatch hook (a PreToolUse hook that denies a missing or malformed input before the agent starts, registered so a hook failure or timeout blocks the call) meets this through the hook. · Check: read the first step; for a hooked agent, confirm the hook exists, names the agent and denies each malformed input the agent depends on, and that the body states it receives a validated message. · Fix: add "If <input> is missing or malformed, stop and reply `<fixed refusal line>` naming it", or put the agent behind such a hook.
- **ADISP-14** · MUST · Does every precondition the job depends on (a file that must exist, a prior step's output, an approved plan) have a stop rule that holds however the agent was invoked? · Check: list the job's preconditions from the steps; find each stop rule. · Fix: add "If <precondition> is not met, stop and change nothing".
- **ADISP-15** · SHOULD · Is every file the agent writes named by an input or by a fixed path in the body? · Check: list the writes in the steps and output section. · Fix: add an output-path input, or state the fixed path.
