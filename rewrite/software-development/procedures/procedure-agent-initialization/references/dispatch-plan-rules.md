# Dispatch plan: rules

What the main thread decides for each plan at SKILL.md's step 6, which `scripts/render-dispatch-plan.sh` can't check for it. The script owns the plan's layout and its question: you fill its JSON, never the Markdown or the dialog.

## Plan input

The input shape and every rule the script checks (each field, its values, the plugins it holds against the installed ones, the technology label, the mode's plugins): `render-dispatch-plan.sh --help`. You Write it to the gate's plan file (`procedure-approval-gate`'s step 1). What only you decide:

- **`tasks`:** which dispatches form a group is SKILL.md's step 5.
- **Direct implementation** (SKILL.md's step 10): `agent` is `main thread`.
- **`replan`** (a step-9 re-plan only, as Step-9 re-plans below sets): `invalid` or `stop-recommended`; leave it out otherwise.
- **`--plans <n>`** (with `--question`): how many plans this run of step 6 shows, one after another; `1` for a step-9 re-plan and for step 10.

## Reasons

- **Each reason cites its plugin's description,** in a few words: what in it matched the task (`loaded`), or what didn't match, or which "Not for …" excludes it (`not_loaded`).
- **A boundary-map drop** (SKILL.md's step 4): `<concern>: owned by <owner>`.
- **A step-9 drop:** `invalid`, `uninstalled after approval` or `faulty files`, as Step-9 re-plans below sets.
- **No plugins at all** (a config value, a doc): `loaded_reason` says why, such as `a config value change, no code`.

## Example

How the reasons read, for one shell `BUILD` dispatch. Illustrative: it assumes `tech-shell`, `standard-clean-code`, `standard-observability` and `standard-testing` are installed; `render-dispatch-plan.sh --help` wins over it on shape.

```json
{"agent": "code-developer", "mode": "BUILD", "technology": "Shell",
 "tasks": ["derive the diagnostic keys from field_keys in review-add-round.sh"],
 "loaded": [
  {"plugin": "tech-shell", "reason": "\"rules for writing scripts\": the change is a shell script"},
  {"plugin": "standard-clean-code", "reason": "\"small flat functions\": it restructures a function"}],
 "not_loaded": [
  {"plugin": "standard-observability", "reason": "\"log levels … metrics and traces\": none is added or changed"},
  {"plugin": "standard-testing", "reason": "\"Not for production code\": a BUILD dispatch; tests are a separate TEST dispatch"}]}
```

## Step-9 re-plans

A re-plan from SKILL.md's step 9 lists the dropped plugin under `not_loaded` with its step-9 reason.

- **`invalid`** (step 2's re-run names it invalid): set `"replan": "invalid"` and show the plan through a show-only gate, with "fix it, then rerun" above it; ask nothing, and hand the dispatch back as `stopped` at the human's next message, since the show-only gate ends the turn: `render-plugin-line.sh` refuses while any plugin is invalid.
- **`uninstalled after approval` or `faulty files`, while the dropped plugin's description still matches the task** (as SKILL.md's step 4 sets): set `"replan": "stop-recommended"`, so the question recommends Stop.
- **Any other re-plan:** no `replan`; the one-plan question (`--plans 1`).
