# Dispatch plan: rules

What the main thread decides for each plan at SKILL.md's step 7, as `generate-dispatch-plan.sh`'s options. The generator checks every rule a script can check and writes the plan JSON; the renderer owns its layout and its question. You fill the options, never the JSON, the Markdown or the dialog. Every free-text value (a task, a reason) is quoted as CLAUDE.md sets. `generate-dispatch-plan.sh --help` is the full option list; the plan rules are its `dispatch-plan-validator.jq`'s, and exit 3 names a broken one.

## Options

- **`--plan-file`:** the gate's plan file, the path `open-gate.sh --plan-path` prints.
- **`--agent`:** the part's agent, such as `code-developer`.
- **`--mode`:** `BUILD`.
- **`--context-file`:** the effort's latest context version, as SKILL.md's step 3 takes it.
- **`--task`:** one per task, in order; two or more make a group (SKILL.md's step 6).
- **`--language <name> --reason <line>`:** the part's language plugin, at most one, its name as `list-plugins.sh` prints it.
- **`--framework <name> --reason <line>`:** each framework plugin the code uses, one per framework, only with `--language`; the generator writes them in plugin-name order.
- **`--load <name> --reason <line>`:** each standard or procedure plugin to load.
- **`--skip <name> --reason <line>`:** every other installed standard and procedure plugin. A language or framework plugin the part doesn't use is left out, never skipped.
- **`--load-reason <line>`:** only with no `--language`, `--framework` or `--load`: why nothing is loaded.
- **`--replan`:** only on a step-10 re-plan (from SKILL.md's step 8 or step 10), as that step's reference sets; leave it out otherwise.
- **`--data 'Plan=<path>'`** (the renderer's, printing the plan): the generator's `PLAN_RECORD:` path, so the plan's Data section names its lasting record.
- **`--plans <n>`** (the renderer's, with `--question`): the plan count step 6 wrote into step 7's todo item, the plans this run shows one after another; `1` for a step-10 re-plan.

## Reasons

- **Each reason cites its plugin's description,** in a few words: what in it matched the task or what the context holds as `procedure-context` read it (`--language`, `--framework`, `--load`), or what didn't match, or which "Not for …" excludes it (`--skip`).
- **A boundary-map drop** (SKILL.md's step 5): `<concern>: owned by <owner>`.
- **A step-10 reason:** `invalid`, `uninstalled after approval` or `faulty files`, as the reference of SKILL.md's step 8 or step 10 sets.
- **No plugins at all** (a config value, a doc): `--load-reason` says why, such as `a config value change, no code`.
