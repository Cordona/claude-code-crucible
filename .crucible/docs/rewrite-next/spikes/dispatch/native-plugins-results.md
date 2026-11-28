# Native plugin loading: results

2026-11-26, Claude Code 2.1.332, Opus main, haiku stand-ins, auto mode, headless unless noted. Three stand-in plugins: 0.9 + 11.9 + 9.8 KB = 22.6 KB (above the largest real set, 21 KB). Kit `kit-native/`, sandboxes `/Users/Shared/crucible-sandbox/native-plugins/<case>`. Design: `native-plugins-design.md`, confirmed by Fable with additions.

## Route 1: agent file with `skills:` frontmatter

| Case | Result |
|---|---|
| File present at session start | All 3 skills preloaded in full before the first step (861 / 11,901 / 9,837 chars), 0 asks |
| Written mid-session, headless | `Agent type 'job-1' not found`: the list is read once |
| Written mid-session, interactive | Not found in the same turn, even after 3 s and 10 s waits. Found at the next turn; all 3 loaded in full |
| Tree from Claude Code (inside the repo) | Loads in full |
| Our tree outside the repo (WorktreeCreate hook) | Loads in full; pwd was `trees/t1`. Skills resolve from main's project, not the agent's folder |
| Agent file in the user-level folder (`$CLAUDE_CONFIG_DIR/agents`) | Works; nothing in the repo |
| Plugin skills with `disable-model-invocation: true` | **Nothing preloaded, no error**; the agent saw no markers |

The checkout: the written files sit under `.claude/` (ignored in the probe), or outside the repo in the user-level folder. Main's skill list holds every plugin skill (init lists probe-a, b, c); the agent list holds every agent file.

No per-skill or total cap was hit at 11.9 KB per skill and 22.6 KB in total.

## Route 2: the agent loads its own plugins with the Skill tool

| Case | Result |
|---|---|
| Job message says "load probe-a, b, c first" | 3 Skill calls, all full text, then the job; 0 asks |
| Job message "go", plus a hook refusing other tools until loaded | **Fails.** The agent reads the refusal as text not from its caller, says "not part of your task", retries and never loads. 7 refusals. The probe's gate also blocked the handback (kit bug), but the agent never tried a Skill call |

## What it means

- Route 1 loads plugins natively, in full, past the start-hook cap, in our tree, with no hook. One limit: a new agent type is seen only at the next turn.
- Route 2 works only when the job message tells the agent; a hook can't make it.
- Plugin skills must stay model-invocable, so main sees each one in its skill list.

## Evidence

Per-case logs under the sandboxes above; marker counts by `kit-native/count.sh <case>`. Transcripts local only.

## After Fable: a turn main starts by itself

Interactive, case `r1-wake`: in one turn main wrote `job-w` and started a background sleeper, then ended its turn. The sleeper's finish notice woke main (no human message); Claude Code showed "1 agent type available", and main started `job-w` in that wake turn: all 3 skills in full. So any new turn counts, including a background agent's notice.

Fable's other points, for the spec talk: the door refuses to write a file naming a skill it can't find as model-invocable (the silent no-load); headless verification kits write their agent files before the session starts; the real Opus kinds and main's skill-list cost go into the auto-mode rerun.
