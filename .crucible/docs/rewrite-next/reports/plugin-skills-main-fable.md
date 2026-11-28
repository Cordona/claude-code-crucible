# Should main be blocked from loading the plugin skills? Fable's opinion (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**Basis:** the runs so far and the design; nothing new was read or run for this.

## Answer

**No hook now.** There is no failure behind it, the harm of the slip is small, and the one time a hook on the Skill tool was tried here (route 2 of the native-plugins spike) the gate failed.

**Watch for it instead, and add the hook only if a run shows main loading one.** What to watch is cheap and named below.

## The weighing

**How bad is the slip?** Main loads `language-kotlin-review` by itself. Nothing breaks: no event, no gate and no agent is touched. The cost is main's context, from a few KB to about 38 KB for a full set. That is real, since main's context is the thing that cracked first in the three-repo run, but it is a cost, not a wrong result.

**The slip that would matter is a different one:** main loading the rules and then doing the build or the review itself. That is not a plugin problem. The Never line covers it ("start an agent to do the effort's work only through a skill that starts agents" and the jobs behind it), and a block on the Skill tool would not stop a main that decided to do the work anyway.

**Does main have a fair reason to read one?** Sometimes, yes:
- the human asks what a standard says;
- a finding cites a rule and main and the human are deciding whether to fix it;
- main is choosing which standards a job needs and the one-line description isn't enough.

A hook would refuse all three. Main would then read the file by its path instead, and the hook would have bought nothing.

**Does an agent need the Skill tool for them?** Not to start: the preload doesn't go through it. I would still not close it to agents, and the proposed hook rightly doesn't.

**What the guard is today, and why it is probably enough.** The description is what a model reads when it decides to load a skill, and each one says whose it is and "Not for main". In the runs so far, with the listing present, I know of no case of main loading one. Dev Beta can say whether that is checked or assumed.

**The cost that is certain** is the listing itself, about 5 KB in every session, and a hook doesn't reduce it.

## What to do instead

1. **Make it a recorded number in every live run:** how many times main called the Skill tool on a plugin's name. It is one count from the run's own audit.
2. **The trigger for the hook:** main loads one unasked in a real run and it costs something (context, or it then does the job itself). Then one hook entry, taking the names from the installed plugins and not from a list in the hook, denying with one line that says what to do: "a job agent's rules; define a job, or read the file if the human asked".
3. **Before trusting that hook,** prove it in auto mode. The Skill gate in the spike did not hold, and a guard that sometimes fires is worse than none.

## For the owner

Nothing to decide unless you want the hook now regardless. My lean: no, and a count in each run.
