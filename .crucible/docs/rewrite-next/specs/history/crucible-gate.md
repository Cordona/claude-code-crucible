# Spec: crucible-gate

The first skill of the new framework. It holds the rules for questions to the human, and the small machinery that guarantees a card reaches the human before the question about it. Judged against `../constitution.md`.

**Home:** `new-rewrite/framework/core/main-thread/crucible-gate/`

```
crucible-gate/
  SKILL.md
  scripts/
    show-card.sh
    lib/owed.sh
  hooks/
    stop/require-card-shown.sh
    pre-tool-use/hold-question-until-card-shown.sh
    pre-tool-use/check-question-shape.sh
```

## 1. What a gate is

Two parts, both always there (owner, 2026-11-21: every gate shows a card; only who compiles it differs):

- **The card:** what you look at before deciding. There are two kinds:
  - **deterministic:** rendered by its owner's script from events and reports (dispatch plan, build/test/review report, test plan challenge). It lives with its owner, never here;
  - **free:** written by main, in its own words, kept short.

  Both are shown the same way: through `show-card.sh`.
- **The question:** always written by main, as a plain AskUserQuestion call, from the concrete scenario. No templates, no question files, no payload script.

## 2. Prose: SKILL.md (~200 words)

What it says, and nothing else:

- **When a gate is worth it:** a decision that matters and that main initiates (start an effort, approve a plan, choose fixes, dispatch, commit). Otherwise act, or ask in a plain sentence.
- **The four question rules (owner's words):**
  1. built from the concrete context and scenario, every time;
  2. a recommended option first, with why;
  3. the human can always answer in their own words (the dialog's built-in "Other"; never add one);
  4. help a human switching between sessions decide fast: the deciding facts in the question, an honest, objective recommendation, and the honest alternative never hidden.
- **Cards:**
  - a deterministic card comes from its owner's script;
  - a free card is a short file main writes.
  
  Either way: run `show-card.sh`, then end the turn with the card exactly as printed, and ask once told to.
- **One positive example:** a question with the facts in it and two options, the recommended one first (PRM-12).
- **On a refusal:** the reason is plain; fix what it names and carry on.

It doesn't describe how the hooks work, list exit codes, or carry Never/Always sections.

## 3. Script: `show-card.sh`

One job: show a card and record it as owed.

- **Usage:** `sh show-card.sh CARD_FILE`
- **What it does:**
  - prints the card file's text on stdout, for main to relay;
  - records it as owed for this session, replacing any card still owed.
- **Reads:** `CLAUDE_CODE_SESSION_ID`. Unset: it prints and records nothing, so a card still shows outside Claude Code.
- **Writes:** `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/crucible-gate/<session>/owed/<id>.json`, which holds `{id, text, status, tries, at}`.
- **Refuses** (exit 2, plain reason) when the file is missing, empty or not text.

## 4. Hooks

Each hook does one job, sits in a folder named for its event, and is callable alone, with `--help` as its contract.

| Hook | Event | Job |
|---|---|---|
| `hooks/stop/require-card-shown.sh` | Stop | **A card is still owed and the last message lacks it** (whitespace-normalised): keep Claude going with "show the card exactly as printed". After 2 tries, let the stop through.<br>**The card is shown:** mark it shown. Keep Claude going with "the card is shown; ask now". |
| `hooks/pre-tool-use/hold-question-until-card-shown.sh` | PreToolUse (AskUserQuestion) | **No card, or a card not yet shown:** deny, saying what to do.<br>**A shown card:** allow, and clear it as the question goes out. |
| `hooks/pre-tool-use/check-question-shape.sh` | PreToolUse (AskUserQuestion) | Every question has a non-empty text. Its first option's label ends with `(Recommended)`, and no other option's does. Every option has a non-empty description (the why). No option is a hand-made "Other". It denies with the reason that names the broken rule. |

The rules all three hooks share:
- **What they ignore:** a subagent's question or stop (non-empty `agent_id`), and a tool other than AskUserQuestion. Both pass untouched.
- **Faults:** a hook fault lets the call through, with a note on stderr. A hook bug never blocks the human.
- **Stale records:** a record older than 30 minutes is stale and ignored.

Two things the hooks don't check:
- **The 2–4 option count:** AskUserQuestion already enforces it.
- **Whether a question is honest or built from the scenario:** that's judgment, so it stays in the prose.

## 5. `lib/owed.sh`

The owed store's few shared rules, sourced by `show-card.sh` and the hooks:
- the store's path;
- safe ids;
- the stale age;
- the tries cap;
- the atomic file write.

It's a module, not a script. Each script still runs alone.

## 6. Written fresh

Everything is written from scratch against this spec and the constitution. Today's code is read only to learn from what it got right; nothing is copied or trimmed. Dropped for good: the 16 question files, the gate renderers, the plan file and gate folder, `gate-failures.md`, and the "procedure-approval-gate:" message protocol.

No versioning anywhere: no version numbers in names, files, fields or text.

## 7. Not yet

- **Answer events** (`gate.<record>.answered`) for the answers downstream pieces depend on. They need `crucible-events`, so they come with `crucible-effort`. How main marks such a question is decided then.
- **Deterministic cards.** Each one arrives with its owner.
- **Deploying into `~/.claude`.**

## 8. Verification

1. **Linters:** the harness rulebook's `lint.sh` and `help-check.sh` (`rewrite/framework/harness/skills/standard-harness-authoring/scripts/`), run directly on the skill folder with `--report-only`: frontmatter, token budget, `--help` length and shape. Proven to run without the harness flow. A finding from an old-style rule that clashes with the constitution is shown to the owner, not obeyed.
2. **Scripts and hooks:** run each one on good and bad input (hook JSON on stdin), and check every refusal reason.
3. **Blind check:** one fresh agent reads only the skill, `constitution.md` and `13-skill-prompting.md`, and reports what breaks them.
4. **Live:** a sandbox in `/Users/Shared`, with the hooks registered in that sandbox's settings only. There are three scenarios:
   - an effort offer with a free card;
   - a question with no card;
   - main trying to ask before relaying the card, which should be denied.

   The owner judges the questions.

## 9. Decided (owner, 2026-11-21)

1. The shape check covers every question main asks, not only gates.
2. The recommended marker is the label suffix `(Recommended)`.
3. `lib/owed.sh` is a shared module inside the skill.

**Why the card rule has no exceptions (2026-11-21):** "every AskUserQuestion follows a shown card" is something a hook can check. Any narrower rule would need the hook to judge which questions deserve a card, and that is judgment in code. A quick question stays a plain sentence instead.
