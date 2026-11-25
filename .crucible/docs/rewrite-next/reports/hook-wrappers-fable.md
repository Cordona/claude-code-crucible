# The owner's hook rule: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `hook-wrappers-proposal.md`, the five `matchers.json` files, and the list of hook scripts as they are on disk. I ran nothing.

## Verdict

**I approve the rule, in form A: one settings entry per component per event, a thin wrapper, its steps in a folder beneath it.** I advise against B, the one runner per event. It reaches the owner's number of five by moving the list of hooks into another file and rebuilding what Claude Code already does.

| Question | Answer |
|---|---|
| 1. The name `steps/`, and the wrapper and step contract | **Yes,** with four notes on the contract |
| 2. A or B | **A.** It gives about 9 entries, not 5, and the owner should know why I'd stop there |
| 3. A hook with one step | **A lone script.** It becomes a wrapper the day it gets a second step |

## 1. A or B

**What the owner's rule protects against** is the count growing with every check: "5 entries, not 50". A does that. Under A the count grows only when a new component needs a hook on an event, which is rare, and never when a check is added.

**What B would be, looked at closely:**

| | A | B |
|---|---|---|
| Settings entries today | about 9 | 5 |
| Where the list of hooks lives | settings, written by the installer | a second list the runner reads, or a search of the install on every tool call |
| Who picks the hooks for a tool call | Claude Code, by matcher, at no cost | the runner, on every tool call of every session, re-doing Claude Code's matching in shell |
| Who combines the answers | Claude Code | the runner, which must follow every answer field Claude Code has now and adds later |
| A fault in one hook | stays in that hook | a fault in the runner drops every hook at once, the two deny hooks on the event log included |
| Time limit | one per entry, so the stop hook keeps its 300 seconds | one for everything on the event |

**B's one real gain** is a fixed order across components, where Claude Code runs them side by side. Nothing needs that today: only one hook rewrites a command, and no two components answer the same call in ways that clash. By the owner's own rule, that is a fix with no failure behind it.

**So B hides the entries; it doesn't remove them.** And it puts a piece in the middle that every hook passes through, which is the shape the constitution warns about.

**If the owner still wants exactly five,** B is buildable, and Dev Beta's cost note is honest. I'd want it kept until a second reason appears, for example running on another tool than Claude Code, where one adapter per event would earn its place.

## 2. The contract

**`steps/` is a fine name.** For the stop hook they are steps in the plain sense; for the tool hooks they are checks run in order, and one name for both is better than two.

Four notes:

1. **The stop hook's wrapper stays what it is.** It isn't a combiner: it has an order, a point of acceptance, and an exit that records the outcome. Only its steps move into `steps/`. The combine rule is for the tool hooks.
2. **No shared combine engine yet.** Two wrappers would use the rule today, and one of them (the event log's two denies) needs only "first deny wins". Write each wrapper plainly. A shared piece can come when a third needs it.
3. **The wrapper never makes a decision of its own.** It prints deny when a step denied, allow only when a step allowed and none denied, and otherwise nothing, so Claude Code's own permissions apply. A step that faults gives no answer, and the others still run.
4. **The wrapper picks steps by tool.** With one entry for Bash, Write and Edit, starting every step on every call wastes a process each time. One `case` on the tool's name keeps it thin and cheap.

**Each step runnable alone,** with the hook's input on stdin and its own answer on stdout, is the best part of the rule: every step gets its own proof cases.

## 3. A hook with one step

**A lone script.** A wrapper that calls one script adds a file and a process and says nothing. The owner's rule is met already: one entry, one script, runnable alone.

**The cost of waiting:** when a second step arrives, the entry's file name changes, so the install must be refreshed. The install check already catches that.

By this, four hooks change and six stay as they are:

| Hook | Change |
|---|---|
| agent-submission, SubagentStop | the eight steps move into `steps/` |
| agent-submission, PreToolUse | one wrapper, with the background refusal, the time limit, the write scope, and the `cd` refusal if it is built |
| crucible-events, PreToolUse | one wrapper over its two denies |
| the other six | lone scripts, unchanged |

## 4. Two cautions for the build

- **The moved steps find their neighbours by counting folders up from their own path.** One level deeper changes every such count, in the eight steps and in `recover-submission.sh`. It is mechanical, and it is exactly the kind of change that passes review and fails at run time. The scripted runners must all pass after it.
- **Rerun the step 3 matrix and its control after the move,** before step 4 goes on. The hooks will have changed three times since that matrix was scored: the write scope, the Bash hook, and now their paths. Otherwise a trial that fails next can't be told apart from a hook that broke.
