# Dispatch plan: template

## Contents

- Rules
- The layout
- The approval question
- Example: one dispatch
- Example: a group (same agent, mode, stack and plugins)
- Example: no plugins
- Example: the question

What the main thread shows the user before it dispatches `code-developer` or implements directly, and the approval question that follows. Fill it the same way every time.

## Rules

- **Render as live Markdown,** never inside a code fence.
- **One item per line.** Markdown joins lines that have no blank line between them, so each key line is its own paragraph, and a reason goes on the line under its plugin with a hard line break (a `\` at the end of the line above), never a nested bullet.
- **Keys in bold, plugin names in `code`, reasons in italics** in parentheses.
- **Always show "Not loaded",** with a reason per plugin left out: it is where an overlook shows. Write `none` when every installed plugin is loaded.
- **Each reason cites its plugin's description,** except a step-9 drop (below) and a boundary-map drop (*(<concern>: owned by `<owner>`)*, from the boundary map SKILL.md's step 4 points to), in a few words: what in it matched the task (Loaded), or what didn't match or which "Not for …" excludes it (Not loaded).
- **No plugins at all** (a config value, a doc): under **Loaded**, `none` with the reason.
- **Direct implementation** (SKILL.md's step 10): **Agent:** `main thread`; **Technology:** none, since it picks standard plugins only. Its question reads `Approve implementing directly with the plugins shown? To change the plugins, choose "Type something" and write what to add or drop.`, with the one-plan options **Approve (Recommended):** implement with the plugins shown, and **Stop:** nothing is implemented.
- **Which dispatches form one plan is SKILL.md's step 5;** each plan gets its own dialog, as SKILL.md's Invariants set (The approval question, below).
- **Show a group** with the agent and its count, the stack once (under **Technology:**), the tasks as a numbered list (1, 2, 3), then the plugins once.

## The layout

One dispatch:

```
**Agent:** <agent>

**Mode:** <BUILD or TEST>

**Technology:** <the tech plugin's label from its plugin line, or none>

**Task:** <the task, one line>

**Loaded**

- `<plugin>`\
  *(<what in its description matched the task>)*

**Not loaded**

- `<plugin>`\
  *(<what in its description didn't match, or the "Not for …" that excludes it>)*
```

A group: the same agent, mode, stack and plugins, different tasks:

```
**Agent:** <agent> (<count>)

**Mode:** <BUILD or TEST>

**Technology:** <label, or none>

**Tasks:**

1. <task>
2. <task>
3. <task>

**Loaded**

- `<plugin>`\
  *(<what in its description matched>)*

**Not loaded**

- `<plugin>`\
  *(<what didn't match, or its "Not for …">)*
```

## The approval question

**Ask with AskUserQuestion,** as SKILL.md's Invariants set: one per plan, with one question.

**Header:** `Dispatch` (or `Dispatch ×<count>` for a group)

**Question:** `Approve this dispatch with the plugins shown? To change the plugins, choose "Type something" and write what to add or drop.` (a group: `Approve these <count> dispatches …`)

**Options,** in this order. With one plan:

1. **Approve (Recommended):** dispatch with the plugins shown
2. **Stop:** nothing is dispatched

With more than one plan:

1. **Approve (Recommended):** dispatch with the plugins shown
2. **Skip:** this plan does not run; the next plan is still shown
3. **Stop all:** no further plan is shown and nothing is dispatched, including plans already approved

A step-9 re-plan (SKILL.md's step 9) whose step-2 re-run names the dropped plugin as invalid asks nothing: show the plan with the plugin under **Not loaded** as *(invalid)*, tell the user "fix it, then rerun", and hand the dispatch back as `stopped`, since `render-plugin-line.sh` refuses while any plugin is invalid.

One that drops a plugin uninstalled after approval, or one with faulty files (a fault only the hook finds while `list-plugins.sh` still lists the plugin), when the dropped plugin's description still matches the task (as SKILL.md's step 4 sets), makes Stop the Recommended option:

1. **Stop (Recommended):** nothing is dispatched; reinstall it (faulty files: fix it), then rerun
2. **Approve:** dispatch with the plugins shown

Otherwise such a re-plan uses the one-plan options above. The dropped plugin is under **Not loaded**, with the reason *(uninstalled after approval)* or *(faulty files)*.

The dialog always adds its own last option, **Type something**: that is how the user changes the plugins.

**On a typed answer:** apply the change, show the plan again with it, and ask again with AskUserQuestion. If the text is unclear, ask the user to clarify, with AskUserQuestion; never guess.

## Example: one dispatch

Illustrative: it assumes these plugins are installed: `tech-shell`, `standard-clean-code`, `standard-observability`, `standard-performance`, `standard-persistence`, `standard-security`, `standard-self-documenting-code`, `standard-testing`.

**Agent:** code-developer

**Mode:** BUILD

**Technology:** Shell

**Task:** derive the diagnostic keys from `field_keys` in `review-add-round.sh`

**Loaded**

- `tech-shell`\
  *("rules for writing scripts": the change is a shell script)*
- `standard-clean-code`\
  *("small flat functions": it restructures a function)*
- `standard-self-documenting-code`\
  *("comments": it rewrites the comment above the function)*
- `standard-performance`\
  *("loops": it iterates over `field_keys`; "a baseline every path meets")*

**Not loaded**

- `standard-observability`\
  *("log levels … metrics and traces": none is added or changed)*
- `standard-persistence`\
  *("a durable store": none is touched)*
- `standard-security`\
  *("untrusted input … secrets": none is touched)*
- `standard-testing`\
  *("Not for production code": a BUILD dispatch; tests are a separate TEST dispatch)*

## Example: a group (same agent, mode, stack and plugins)

Illustrative, with the same install as the example above.

**Agent:** code-developer (2)

**Mode:** BUILD

**Technology:** Shell

**Tasks:**

1. derive the diagnostic keys from `field_keys`
2. fix the usage text of `review-create.sh`

**Loaded**

- `tech-shell`\
  *("rules for writing scripts": both change shell scripts)*
- `standard-clean-code`\
  *("small flat functions": task 1 restructures a function)*
- `standard-self-documenting-code`\
  *("comments": task 1 rewrites the comment above the function)*
- `standard-performance`\
  *("loops": task 1 iterates over `field_keys`)*

**Not loaded**

- `standard-observability`\
  *("log levels … metrics and traces": none)*
- `standard-persistence`\
  *("a durable store": none is touched)*
- `standard-security`\
  *("untrusted input … secrets": none)*
- `standard-testing`\
  *("Not for production code": a BUILD dispatch)*

## Example: no plugins

Illustrative: it assumes only `tech-shell` and `standard-clean-code` are installed.

**Agent:** code-developer

**Mode:** BUILD

**Technology:** none

**Task:** raise the retry limit in `config/ci.yml` from 2 to 3

**Loaded**

- none\
  *(a config value change, no code)*

**Not loaded**

- `tech-shell`\
  *("rules for writing scripts": no shell code is written)*
- `standard-clean-code`\
  *("clean code in any language": no code is written)*

## Example: the question

**Header:** Dispatch

**Question:** Approve this dispatch with the plugins shown? To change the plugins, choose "Type something" and write what to add or drop.

**Options:** (one plan)

1. Approve (Recommended)
2. Stop

(and the dialog's own **Type something**)
