# The permission proposal after P16: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** the P16 rows in `evidence/stop-hook-probe/results.md`, Dev Beta's five-point proposal, and the installer's current permission entries.

**Not done:** I ran nothing and did not open the P16 logs. My preferred design in section 2 rests on one thing nobody has probed yet; it is named there.

## Verdict

**The probe answers what I asked, and it changes my view on one point: a write-scope hook for the builder and tester is earned.** I agree with points 4 and 5 as they are. For points 1 to 3 I'd reach the same result with one mechanism instead of three, and without `acceptEdits`.

| # | Dev Beta proposes | My view |
|---|---|---|
| 1 | Job agents set `permissionMode: acceptEdits` | **I'd avoid it.** It opens more than the job needs, and it fails open |
| 2 | The installer adds the space to the additional directories | **Already there.** The installer has done this since before step 2 |
| 3 | New deny rules, and a write-scope hook per agent | **Yes to the scope, as one hook that allows.** No new deny rules |
| 4 | Bash stays ask-based; no machine-wide git list | **Agree** |
| 5 | The `agent-conduct` line, unchanged | **Agree** |

## 1. Why the write scope is earned

I said last time that the reviewer's hook was needed only if the mode accepts edits. P16 adds a fact that makes the scope worth having for the builder and tester in any mode.

**The slip is realistic.** Main sits in the repo, and a job agent starts there too. Its tree is a second copy of the same files elsewhere. A relative path, or a path copied from main's context, edits the owner's checkout, not the tree. The stop hook's tree check looks only at the tree, so it would never see it.

A hook that refuses such a write, and names the tree in its reason, turns that slip into one corrected call.

## 2. One mechanism in place of three

Dev Beta's design has three parts that must agree: a mode in each definition, deny rules in the installer, and a hook per agent. I'd use one.

**One hook on Write and Edit, in `agent-submission`,** next to the Bash hook:
- it finds the calling agent's job, as the stop hook does;
- the job's kind says what it may write. That is one word in the agent's own `submissions/<kind>.json`: its report only, or its tree and its report;
- a write inside that scope is **allowed** by the hook; a write outside it is **denied**, the reason naming where the agent may write;
- a call from main, or from an agent with no job, passes untouched.

**Why per kind, not per agent:** a test-plan job belongs to the tester and may change nothing in the tree. The stop hook already refuses that at the end; the scope should match it.

**What this buys over `acceptEdits`:**

| | `acceptEdits` plus a deny hook | One hook that allows |
|---|---|---|
| A hook fault | every write goes through unasked | Claude Code asks, as in any session |
| What the mode opens besides Write | `rm`, `mv`, `touch` across the repo and the whole space, which no write hook sees | nothing |
| Depends on main's own mode | yes: P16a shows a mode acts only within what main allows | no |
| Parts to keep in step | three | one |
| The reviewer's report | needs the mode too, for an agent that changes nothing | the same hook, scope "report" |

**What it costs:** a builder that needs `rm` or `mv` for a refactor is asked once, or denied when headless. Under `acceptEdits` it would not be. I think being asked is right for deleting files.

**The one thing unprobed:** that a hook's "allow" on a Write lets a background agent write to its tree and its report in `default` mode, with no allow rule. P15 showed "allow" works for Bash. If the probe says no for Write, Dev Beta's design is the fallback, and then I'd want its hook exactly as proposed.

**On my earlier words.** For the Bash hook I said a timing hook must not change what the human approves. This hook is different in kind: saying what a job may write is its whole purpose, and the scope is the job's own contract.

## 3. The deny rules

**None are needed in my version, and I'd add none in Dev Beta's either without a check first.**
- The events folder already has its deny rule. One thing to confirm: that an `Edit` rule also stops `Write`. If not, add the `Write` twin.
- A pinned report is a read-only file. The step 3 run showed a late write to it failing by itself.

## 4. Bash by asking

**Agree, and the owner should know what it feels like.**
- **First runs in a project:** each new command form from an agent asks the human, naming the agent. The agent waits. With several reviewers at once that is a burst of prompts.
- **After that:** "don't ask again" keeps the rule, so a project settles within a job or two.
- **A waiting agent is safe for the job model.** It is still running, so main's turn end doesn't end its job.
- **Headless runs,** like the lab, pass their own allow-list.

This is the human's permission system doing its job. A machine-wide list written by the framework would take that away from the owner, and I'd still not add one.

## 5. Smaller

- **The reviewer gets `Write` in its tools** in both designs. `Edit` only if repairs fail without it.
- **The Docs instruction injected into tool output** was ignored by the agents, as the first line of `agent-conduct` asks. Nothing to change. The sandbox should keep it, since a real session has the same.

## 6. What I'd put to the owner

1. Probe the hook's "allow" on Write and Edit: a background agent, main in `default`, headless and interactive.
2. If it holds: one write-scope hook, the scope per kind in the agent's submission file, no mode in the definitions.
3. If it doesn't: Dev Beta's design as proposed.
4. Bash by asking, and the `agent-conduct` line, either way.
5. Then rerun the two trials before the counted runs, with main started in the repo.
