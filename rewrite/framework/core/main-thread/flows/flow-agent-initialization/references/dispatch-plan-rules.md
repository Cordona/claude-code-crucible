# Dispatch plan: rules

What the main thread decides for each plan at SKILL.md's step 7, as `generate-dispatch-plan.sh`'s options. `generate-dispatch-plan.sh --help` is the full option list.

## Options

- **`--plan-file`:** the gate's plan file, the path `open-gate.sh --plan-path` prints.
- **`--agent`:** the part's agent, such as `code-developer`.
- **`--mode`:** `BUILD`.
- **`--context-file`:** the effort's latest context version, as SKILL.md's step 3 takes it.
- **`--task`:** one per task, in order; two or more make a group (SKILL.md's step 6).
- **`--language <name> --reason <line>`:** the part's language plugin, at most one, its name as `list-plugins.sh` prints it.
- **`--framework <name> --reason <line>`:** each framework plugin the code uses, one per framework, only with `--language`.
- **`--load <name> --reason <line>`:** each standard or procedure plugin to load.
- **`--skip <name> --reason <line>`:** every other installed standard and procedure plugin.
- **`--load-reason <line>`:** why nothing is loaded. Use it only with no `--language`, `--framework` or `--load`, which only a `code-reviewer` correctness seat has.
- **`--replan`:** only on a step-10 re-plan (from SKILL.md's step 8 or step 10), as that step's reference sets; leave it out otherwise.

## Reasons

- **Each reason cites its plugin's description** in a few words. For `--language`, `--framework` and `--load`: what in it matched the task, or what the context holds as `procedure-context` read it. For `--skip`: what didn't match, or which "Not for …" excludes it.
- **A boundary-map drop** (SKILL.md's step 5): `<concern>: owned by <owner>`.
- **No plugins at all** (a `code-reviewer` correctness seat only): `--load-reason` says why, such as `the correctness seat, no lens`.
