# Native plugins: 10 initializations

2026-11-26, Claude Code 2.1.332, one interactive session, auto mode, Opus main, haiku stand-in bodies. Design confirmed by Fable (5 from files present at start, 5 written in the session; every start in our tree; two agents from one file; one resume). Kit `kit-native10/` (setup.sh, door.sh, init-event.sh, check.py, turn.sh); sandbox `/Users/Shared/crucible-sandbox/native-plugins/ten`.

Plugins: the real files of `new-rewrite/.../plugins` and `core/plugins/standards`, each installed as one project skill (references/build.md and review.md as their own skills), with `disable-model-invocation` removed.

## Result: pass

| Agent | Kind+set file | File from | Started at | Plugins byte-equal | Size | agent.initialized |
|---|---|---|---|---|---|---|
| A | builder-kotlin-spring | session start | human turn | 4/4 | 12.7 KB | 1 |
| B | tester-kotlin | session start | human turn | 3/3 | 24.5 KB | 1 |
| C | reviewer-kotlin-spring | session start | human turn | 4/4 | 13.7 KB | 1 |
| D | reviewer-kotlin-spring (same file as C) | session start | human turn | 4/4 | 13.7 KB | 1 |
| E | builder-php-laravel | session start | human turn | 4/4 | 13.6 KB | 1 |
| F | tester-ts-react | written a turn earlier | human turn | 4/4 | 34.6 KB | 1 |
| G | reviewer-kotlin-security | written a turn earlier | human turn | 4/4 | 38.0 KB | 1 |
| H | builder-rust | written in G's turn | wake turn (sleeper's notice) | 2/2 | 8.9 KB | 1 |
| I | builder-shell | written in G's turn | wake turn (H's notice) | 2/2 | 9.7 KB | 1 |
| J | tester-php | written a turn earlier | human turn | 4/4 | 34.1 KB | 1 |

- 10/10 agents: every plugin byte-equal to its file body, each in its own tree (t1–t10, our WorktreeCreate hook).
- 10/10: exactly one `agent.initialized`, right agent id, type and plugin list. C and D (one file) got one each.
- Resume of A: SubagentStart fired again; the event hook wrote nothing (refused as a repeat); Claude Code did **not** preload the plugins a second time (0 repeated blocks).
- 0 permission asks.

## Recorded, no pass line

- When a file appears, main gets an `agent_listing_delta` with one line per new type (~300 bytes).
- Main's skill list: 30 plugin entries, 7.1 KB of 27.2 KB. Main invoked none of them.
- The door refused the unmodified real plugin (`disable-model-invocation: true`): "skill hidden-kotlin is hidden from the model; agent file not written".

## Findings for the design

1. Every real plugin is `disable-model-invocation: true` today: natively it would silently not load. They must become model-invocable (`user-invocable: false` kept), which puts them in main's skill list.
2. `skills:` preloads a skill's SKILL.md only, not its references/. A plugin's build.md or review.md must be its own skill, or folded into the SKILL.md the kind needs.
3. Haiku stand-ins: the real Opus kinds following the plugins belongs in the 15-kind auto-mode rerun.

## Fable's verdict

The pass stands; route 1 is proven as a mechanism. Finding 1: accept (no other native way); main carries the plugin entries in every session where they are installed, effort or not; shrink plugin descriptions to a few words, build nothing to hide them. Finding 2: build.md and review.md as their own skills, not folded. Limits: one session, the kit's own byte-equal check, no cap hit at 38 KB (not "no cap"), a resumed agent's plugins live only in its earlier context. To the owner before a spec: where the files live, the plugin change, the `agent.initialized` shape. Then the auto-mode rerun of the 15 real kinds on this route.
