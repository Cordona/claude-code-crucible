# Dispatch plan: rules

What the main thread decides for each plan at SKILL.md's step 7, as `generate-dispatch-plan.sh`'s options. The generator checks every rule a script can check and writes the plan JSON; the renderer owns its layout and its question. You fill the options, never the JSON, the Markdown or the dialog. Every free-text value (a task, a reason) is quoted as CLAUDE.md sets. `generate-dispatch-plan.sh --help` is the full option list and every rule it checks.

## Options

- **`--plan-file`:** the gate's plan file, the path `open-gate.sh --plan-path` prints.
- **`--agent`:** the part's agent, such as `code-developer`; `main thread` for direct implementation (SKILL.md's step 11).
- **`--mode`:** `BUILD`.
- **`--context-file`:** the effort's latest context version, as SKILL.md's step 3 takes it.
- **`--task`:** one per task, in order; two or more make a group (SKILL.md's step 6).
- **`--load <name> --reason <line>`:** each plugin to load, its name as `list-plugins.sh` prints it.
- **`--skip <name> --reason <line>`:** every other installed plugin.
- **`--loaded-reason <line>`:** only with no `--load`: why nothing is loaded.
- **`--replan`:** only on a step-10 re-plan, as Step-10 re-plans below sets; leave it out otherwise.
- **`--plans <n>`** (the renderer's, with `--question`): the plan count step 6 wrote into step 7's todo item, the plans this run shows one after another; `1` for a step-10 re-plan and for step 11.

## Reasons

- **Each reason cites its plugin's description,** in a few words: what in it matched the task or what the context holds as `procedure-context` read it (`--load`), or what didn't match, or which "Not for …" excludes it (`--skip`).
- **A boundary-map drop** (SKILL.md's step 5): `<concern>: owned by <owner>`.
- **A step-10 drop:** `invalid`, `uninstalled after approval` or `faulty files`, as Step-10 re-plans below sets.
- **No plugins at all** (a config value, a doc): `--loaded-reason` says why, such as `a config value change, no code`.

## Example

How the options and reasons read for one shell `BUILD` part whose context holds no tracker link. Illustrative: it assumes `tech-shell`, `standard-clean-code`, `standard-observability`, `standard-testing` and `procedure-read-trackers` are installed; `generate-dispatch-plan.sh --help` wins over it.

```
sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/flow-agent-initialization/scripts/dispatch-plan/generate-dispatch-plan.sh" \
  --plan-file '<the gate plan file>' --agent code-developer --mode BUILD \
  --context-file '<the CONTEXT_FILE path>' \
  --task 'derive the diagnostic keys from field_keys in review-add-round.sh' \
  --load tech-shell --reason '"rules for writing scripts": the change is a shell script' \
  --load standard-clean-code --reason '"small flat functions": it restructures a function' \
  --skip standard-observability --reason '"log levels … metrics and traces": none is added or changed' \
  --skip standard-testing --reason '"Not for production code": a BUILD part; tests are a separate dispatch' \
  --skip procedure-read-trackers --reason '"a dispatch'\''s context holds a tracker link": its links hold no GitHub, GitLab or Jira issue'
```

## Step-10 re-plans

A re-plan from SKILL.md's step 10 for a `PLUGIN` denial moves the dropped plugin to `--skip`, its reason the step-10 drop step 2's re-run shows: `invalid` when it names the plugin invalid, `uninstalled after approval` when it no longer lists it, `faulty files` when it still lists it (a fault only the hook finds).

- **`invalid`:** add `--replan invalid` and show the plan through a show-only gate (`open-gate.sh --show-only`), with "fix it, then rerun" above it. Ask nothing. The show-only gate ends the turn, so hand the dispatch back as `stopped` at the human's next message.
- **`uninstalled after approval` or `faulty files`, while the dropped plugin's description still matches the task** (as SKILL.md's step 5 sets): add `--replan stop-recommended`.
- **A denial naming `CONTEXT`,** with `PLUGIN` or not: no re-plan; SKILL.md's step 10 stops that dispatch. A `CONTEXT-STALE` denial with no `CONTEXT` is re-planned with the latest version, as step 10 sets.
- **Any other re-plan:** no `--replan`; the one-plan question, `--plans 1`.
