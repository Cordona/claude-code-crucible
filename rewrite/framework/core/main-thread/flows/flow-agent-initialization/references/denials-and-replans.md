# Denials and re-plans

Step numbers are SKILL.md's.

## Step 8: exit 3

Route by the token a stderr problem leads with, right after its `generate-agent-dispatch.sh: <option> <value>: `, never by the text after it.

- **A problem led by `CONTEXT-CHANGED` or `CONTEXT-STALE`:** the human approved another file; take that plan back to step 7 with the latest version, then run step 8 for it again.
- **A problem led by `NO-GATE-RECORD`:** the approval is lost (its gate record expired or is gone); take that plan back to step 7 to ask it again, then run step 8 for it again.
- **A problem led by `PLUGIN`:** a plugin the plan approved is now uninstalled or invalid, named after the token. Run step 2 again, then re-plan that plan as step 10's `PLUGIN` bullet below sets, with its stop lines and hand-backs; on Approve, run step 8 for it again.

## Step 10: hook denial

The Agent call returns `PreToolUse:Agent hook error:` with a reason starting `flow-agent-initialization:`, in the shape `prepare-agent-prompt.sh --help` sets. Route by the KIND word that starts each problem, right after its list number or `**Problem:** `: `DISPATCH`, `AGENT`, `CONTEXT`, `CONTEXT-STALE`, `PLUGIN`, `SEAT`, `BACKGROUND` or `SKILL`, never by the text after it. Relay the reason to the human word for word, as printed, only on a bullet that stops the dispatch; a re-plan or a new step-8 run relays none of it:

- `SKILL`, whatever else the reason names: a skill the agent file's frontmatter preloads is not installed; relay the reason, and hand the dispatch back as `stopped: preloaded skill missing`; installing it is the human's.
- `PLUGIN`, with no `CONTEXT` or `CONTEXT-STALE`: an approved plugin uninstalled, invalid or with faulty files. Run step 2 again (here an exit 3 naming only that plugin goes on). With `faulty files` (step 2's re-run still lists it), whatever the plugin's kind (language, framework, standard or procedure), re-plan nothing: show the line `⛔ Stopped · the <name> plugin's files changed after approval: this part was not dispatched.` as step 1's reinstall line is shown, and hand the dispatch back as `stopped: plugin files changed for <name>`. Otherwise, re-plan at step 7 as Step-10 re-plans below sets: it drops that plugin, but keeps an invalid framework plugin in the plan with reason `invalid`; on Approve, steps 8–9 for it. A language plugin is never kept: the part stops, its frameworks with it, and nothing is re-planned; show step 5's stop line, and hand the dispatch back as `stopped: no installed plugin for <name>` (an invalid plugin counts as not installed here). A framework plugin is dropped or kept and re-planned, as Step-10 re-plans below sets. In these lines, `<name>` is the plugin's install name, copied from the problem, never typed: the name after `PLUGIN` in step 8's problem (`PLUGIN language-shell uninstalled`), or the folder after `skills/` in the hook problem's path.
- `CONTEXT-STALE`, with no `CONTEXT`: the context got a new version after the dispatch was written; take its plan back to step 7 with the latest version, as step 8's exit 3 does, with any `PLUGIN` problem handled in the same re-plan as the bullet above sets; on Approve, steps 8–9 for it.
- `CONTEXT`, alone or with `CONTEXT-STALE` or `PLUGIN`: relay the reason, hand the dispatch back as `stopped`, and re-plan nothing; the human decides whether to extend the context through `procedure-context`.
- `SEAT`, the dispatch's seat missing from `seats.json`, unreadable, not open or with no worktree: relay the reason, and hand the dispatch back as `stopped: seat not open`; the seats are the calling flow's.
- Only `BACKGROUND`: the calling flow called Agent in the foreground; hand back the same `DISPATCH:` line, unchanged, for the calling flow to call again in the background.
- Only `DISPATCH` or `AGENT`: run step 8 once more for that dispatch, and hand back its new `DISPATCH:` line.
- A reason with no KIND (a fault of the hook, its install or the host): relay the reason, and hand the dispatch back as `stopped: hook failed`.

## Step-10 re-plans

A re-plan from step 10 for a `PLUGIN` denial gives the named plugin the reason step 2's re-run shows: `invalid` when it names the plugin invalid, `uninstalled after approval` when it no longer lists it. It drops the plugin, except an invalid framework plugin, which stays in the plan. Where the plugin goes:

- **A standard or procedure plugin:** to `--skip`, with that reason.
- **A framework plugin named `invalid`:** it stays as `--framework <name> --reason invalid`, with `--replan invalid`.
- **A framework plugin `uninstalled after approval`:** re-plan the part at step 7 without it, as step 10's `PLUGIN` bullet above sets for a dropped plugin, its language plugin's reason saying the framework has no installed plugin (step 5).
- **A language plugin:** never re-planned; step 10's `PLUGIN` bullet above stops the part, its frameworks dropped with it.
- **A plugin with `faulty files`, of any kind:** never re-planned; step 10's `PLUGIN` bullet above stops the part.

Then, by the plan's step-10 reasons:

- **`invalid`:** add `--replan invalid` and show the plan through a show-only gate (`open-gate.sh --show-only`), with no note above it. Ask nothing. The show-only gate ends the turn, so hand the dispatch back as `stopped` at the human's next message.
- **`uninstalled after approval`, for a dropped standard or procedure plugin whose description still matches the task** (as step 5 sets): add `--replan stop-recommended`. Never for a framework plugin: one dropped as `uninstalled after approval` is re-planned under its language plugin as step 5 sets, with no stop recommended.
- **A denial naming `CONTEXT`,** with `PLUGIN` or not: no re-plan; step 10's `CONTEXT` bullet above stops that dispatch. A `CONTEXT-STALE` denial with no `CONTEXT` is re-planned with the latest version, as step 10's `CONTEXT-STALE` bullet above sets.
- **Any other re-plan:** no `--replan`; the one-plan question, `--plans 1`.
