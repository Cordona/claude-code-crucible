# Denials and re-plans

What step 8 does on an exit 3, what step 10 does on a hook denial, and how a step-10 re-plan sets its plan; read at step 8 on an exit 3 and at step 10 on a hook denial. Step numbers are SKILL.md's.

## Step 8: exit 3

Route by the token a stderr problem leads with, right after its `generate-agent-dispatch.sh: <option> <value>: `, never by the text after it.

- **A problem led by `CONTEXT-CHANGED` or `CONTEXT-STALE`:** the human approved another file; take that plan back to step 7 with the latest version, then run step 8 for it again.
- **A problem led by `NO-GATE-RECORD`:** the approval is lost (its gate record expired or is gone); take that plan back to step 7 to ask it again, then run step 8 for it again.
- **A problem led by `BASELINE-EMPTY`:** that dispatch never reached the tree; run step 8 once more without `--baseline-from`.
- **A problem led by `PLUGIN`:** a plugin the plan approved is now uninstalled or invalid, named after the token. Run step 2 again, then re-plan that plan as step 10's `PLUGIN` bullet below sets, with its stop lines and hand-backs; on Approve, run step 8 for it again.
- **An exit 3 with none of these tokens:** as step 8's any other exit.

## Step 10: hook denial

The Agent call returns `PreToolUse:Agent hook error:` with a reason starting `flow-agent-initialization:`, in the shape `prepare-agent-prompt.sh --help` sets. Route by the KIND word that starts each problem, right after its list number or `**Problem:** `: `DISPATCH`, `AGENT`, `CONTEXT`, `CONTEXT-STALE`, `PLUGIN`, `REPORT`, `BASELINE` or `BASELINE-WRITE`, never by the text after it. Relay the reason to the human word for word, as printed, only on a bullet that stops the dispatch; a re-plan or a new step-8 run relays none of it, since the plan or the dispatch it leads to is what goes on:

- `PLUGIN`, with no `CONTEXT` or `CONTEXT-STALE`: an approved plugin uninstalled, invalid or with faulty files. Run step 2 again (here an exit 3 naming only that plugin goes on), then re-plan at step 7 as Step-10 re-plans below sets: it drops that plugin, but keeps an invalid framework plugin in the plan with reason `invalid`; on Approve, steps 8–9 for it. A language plugin is never kept: the part stops, its frameworks with it, and nothing is re-planned. With `faulty files` (step 2's re-run still lists it), show the line `⛔ Stopped · the <name> plugin's files changed after approval: this part was not dispatched.` as step 1's reinstall line is shown, and hand the dispatch back as `stopped: plugin files changed for <name>`; otherwise, for a language plugin only, show step 5's stop line, and hand the dispatch back as `stopped: no installed plugin for <name>`, an invalid plugin counting as not installed here; a framework plugin is dropped or kept and re-planned, as Step-10 re-plans below sets. In these lines, and in the framework stops Step-10 re-plans below sets, `<name>` is the language or framework plugin's install name, copied from the problem, never typed: the name after `PLUGIN` in step 8's problem (`PLUGIN language-shell uninstalled`), or the folder after `skills/` in the hook problem's path.
- `CONTEXT-STALE`, with no `CONTEXT`: the context got a new version after the dispatch was written; take its plan back to step 7 with the latest version, as step 8's exit 3 does, with any `PLUGIN` problem handled in the same re-plan as the bullet above sets; on Approve, steps 8–9 for it.
- `CONTEXT`, alone or with `CONTEXT-STALE` or `PLUGIN`: relay the reason, and hand the dispatch back as `stopped` (SKILL.md's Never: re-plan nothing); the human decides whether to extend the context through `procedure-context`.
- `BASELINE-WRITE`, a baseline the hook could not write, or `BASELINE`, a baseline file that holds no valid baseline: relay the reason, and hand the dispatch back as `stopped: hook failed`, since the human must fix what it names first.
- Only `DISPATCH`, `AGENT` or `REPORT`: run step 8 once more for that dispatch, and hand back its new `DISPATCH:` line.
- A reason with no KIND (a fault of the hook, its install or the host, such as a missing or empty `agent-context-rules.md` in `procedure-context`'s references, which the reason names): relay the reason, and hand the dispatch back as `stopped: hook failed`.

Whenever step 10 runs step 8 for a dispatch whose earlier Agent call went through to the agent, add `--baseline-from '<the dispatch file it replaces>'`, so the new dispatch keeps the first call's baseline.

## Step-10 re-plans

A re-plan from step 10 for a `PLUGIN` denial gives the named plugin the reason step 2's re-run shows: `invalid` when it names the plugin invalid, `uninstalled after approval` when it no longer lists it, `faulty files` when it still lists it (a fault only the hook finds). It drops the plugin, except an invalid framework plugin, which stays in the plan. Where the plugin goes:

- **A standard or procedure plugin:** to `--skip`, with that reason.
- **A framework plugin named `invalid`:** it stays as `--framework <name> --reason invalid`, with `--replan invalid`.
- **A framework plugin `uninstalled after approval`:** re-plan the part at step 7 without it, as step 10's `PLUGIN` bullet above sets for a dropped plugin, its language plugin's reason saying the framework has no installed plugin (SKILL.md's step 5).
- **A framework plugin with `faulty files`:** re-plan nothing; it is still installed, so show the line `⛔ Stopped · the <name> plugin's files changed after approval: this part was not dispatched.`, `<name>` the framework plugin's install name as step 10's `PLUGIN` bullet above sets, as SKILL.md's step 1 reinstall line is shown, and hand the dispatch back as `stopped: plugin files changed for <name>`.
- **A language plugin:** never re-planned; step 10's `PLUGIN` bullet above stops the part, its frameworks dropped with it.

Then, by the plan's step-10 reasons:

- **`invalid`:** add `--replan invalid` and show the plan through a show-only gate (`open-gate.sh --show-only`), with no note above it: the renderer prints it as blocked, naming the invalid plugins and what to do. Ask nothing. The show-only gate ends the turn, so hand the dispatch back as `stopped` at the human's next message.
- **`uninstalled after approval` or `faulty files`, for a dropped standard or procedure plugin whose description still matches the task** (as SKILL.md's step 5 sets): add `--replan stop-recommended`. Never for a framework plugin: one dropped as `uninstalled after approval` is re-planned under its language plugin as SKILL.md's step 5 sets, with no stop recommended.
- **A denial naming `CONTEXT`,** with `PLUGIN` or not: no re-plan; step 10's `CONTEXT` bullet above stops that dispatch. A `CONTEXT-STALE` denial with no `CONTEXT` is re-planned with the latest version, as step 10's `CONTEXT-STALE` bullet above sets.
- **Any other re-plan:** no `--replan`; the one-plan question, `--plans 1`.
