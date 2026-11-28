# Sealing framework scripts from reading: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `read-sealing-proposal.md`, today's guard step `deny-internals-read.sh` (read in full for my last review), the folders every component has today, and the agents' prose for any script it tells an agent to run.

**Not done:** I ran nothing. I did not check how plugins are installed or read, so section 2.1 states a risk to check, not a fault I saw.

## Verdict

**I approve the direction, with three changes. Without the first, the build could stop agents reading their own plugin files.**

| # | Change | Why |
|---|---|---|
| 1 | Keep the guard a list of sealed folders; don't turn it into a list of readable ones | a list of readable folders refuses everything nobody thought of, plugins first |
| 2 | Drop "only the skills its own frontmatter loads" | the guard would have to read agent definitions on every call, with no failure behind it |
| 3 | Name `scripts/agent/` in the contract, and build nothing for it yet | no agent runs a framework script today, and the one example is better done by main |

| Question | Answer |
|---|---|
| 1. The folder contract, and `scripts/agent/` | **Yes to the contract.** The folder's name is right; it has no first tenant yet |
| 2. One guard, or a step per audience | **One step.** The audience changes one line of it |
| 3. Should the install check enforce the contract | **Yes.** It is what makes a short list of sealed folders complete |
| 4. Scripts agents must run, beyond tracker reads | **None today, and I'd not add tracker reads either** |

## 1. What is right

- **One structure, the same in source and installed,** is the point that makes everything else cheap. It already holds: every component has only `scripts/main`, `scripts/internal`, `scripts/lib`, `hooks`, `events` and, for agents, `submissions`.
- **Sealing main's scripts from agents is worth more than context.** An agent that runs main's commit script or the script that ends a job does main's work with nobody's consent. Agents don't know those scripts exist, and this keeps it so.
- **Dropping the exception for subagents** is right for the same reason.
- **Keeping the framework's own repo exempt** is right: that is us working on it.

## 2. The three changes

### 2.1 Sealed folders, not readable folders

The proposal says "everything else in the framework is refused to both". That turns the guard from "these folders are sealed" into "only these are open". The framework holds more than components: the plugins, with their `SKILL.md`, their `build.md` and `review.md`, and their `references/`. Agents are built from them. A list of open folders that forgets one refuses it, and the agent fails in a way nobody connects to the guard.

**Keep today's shape:**

| Sealed | For |
|---|---|
| `scripts/internal/`, `scripts/lib/`, `hooks/`, `events/`, `submissions/` | main and agents |
| `scripts/main/` | agents |

Everything else stays readable. With the install check refusing any other folder in a component (question 3), this list is complete, so nothing is lost against the stricter wording.

### 2.2 "Only its own skills"

To know which skills an agent's frontmatter loads, the guard would read the agent's definition on every Read, Grep, Glob and Bash call. Claude Code already puts those skills in the agent's context, so the agent has no need to read them from disk. And an agent reading another agent's `SKILL.md` harms nothing. I'd leave `SKILL.md` and `references/` readable to all.

### 2.3 `scripts/agent/`

**The name and the place are right.** It reads as what it is, and it sits beside `scripts/main/`.

**It has nothing to hold today.** No agent's prose tells it to run a framework script. The proposal's one example is reading a tracker link. I'd not give that to an agent:
- it would call GitHub, GitLab or Jira with the owner's login, unattended and in the background;
- the account and consent gates are main's, and an agent can't hold them;
- the outside review already works the other way: main fetches the threads, and the job is handed a file.

So main reads the link and hands the text to the job. That keeps agents off the owner's accounts, and it is one rule, not two.

**What I'd build now:** the contract names `scripts/agent/` as open to agents. No folder is created, and the installer writes no allow rules for it, until a first script needs it.

## 3. The four questions

1. **The contract:** yes, as changed above. Add a line for what a component may hold besides these folders: its `SKILL.md` or its agent definition, and `references/`.
2. **One step.** The costly part is resolving the path, and both audiences need it. The audience adds one folder to the sealed list. Rename the step: it no longer guards only main.
3. **Yes.** A component with a folder outside the contract is reported by the install check. That is the invariant in code; the guard only applies it.
4. **None.** Committing is the stop hook's. Tracker writes are main's, as the proposal says. Tracker reads I'd also leave with main, section 2.3.

## 4. Two things to say plainly

- **What the guard is.** It matches paths in tool calls. It stops a mistake, a model that wanders into the internals. It is not a wall against a command built to get round it, and the framework has never claimed that.
- **What it costs.** The step now does its full work on every sub-agent's Read, Grep, Glob and Bash call, where today it steps aside at once. That adds to the per-call time I asked Dev Beta to measure in the matrix rerun.

## 5. Order

The matrix rerun is the regression test for every hook. This changes a hook again. I'd build it before that rerun is scored, or rerun the cells it touches after: one cell per agent type is enough, since a sealed folder an agent needed would show as a failed job.
