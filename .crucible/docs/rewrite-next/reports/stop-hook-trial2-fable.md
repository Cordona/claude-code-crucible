# Trial 2 and the four proposals: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** the "Trial 2" section of `evidence/stop-hook-real/README.md`, and the builder's, reviewer's and shared skill's prose where they describe `summary` and `at`.

**Not done:** I ran nothing, and I did not open trial 2's raw logs or transcripts. What I say in section 2 about how Claude Code starts a sub-agent is from memory, which is why it is a probe.

## Verdict

**The permission design held, and the trial failed on one thing: the agent isn't in its tree, so its first command is a `cd` chain that Claude Code refuses.** I agree with all four proposals. Proposal 2 is the real fix and proposal 1 is the bridge, and I'd narrow proposal 1 so it can't break real projects.

| # | Proposal | My view |
|---|---|---|
| 1 | The Bash hook pre-empts forms Claude Code will refuse, with a reason the agent can act on | **Yes, kept to two forms, and never a plain `cd` chain** |
| 2 | Probe: can a sub-agent start in its tree? | **Yes, and add one question** |
| 3 | The `agent-conduct` line comes out | **Yes.** It failed the test I set for it |
| 4 | The scorer checks that allowed checks were run | **Yes** |

## 1. Proposal 1: the hook's own refusal

**Right in kind.** A hook that answers at the moment of the slip, every time, with words the agent can act on, is what the prose line could not be. P17c showed agents follow such a reason.

**It also helps the owner's interactive sessions,** not only the headless lab. Claude Code always asks about `cd` before a git command, so each reviewer would put that prompt in front of the human. With the hook the agent switches to `git -C`, which the human can allow once.

**Three limits I'd put on it:**

1. **Never refuse `cd` as such.** Claude Code's guard is about `cd` before a version-control command. Many real projects' checks need to run from the project folder: `npm test`, `make`, `pytest`. A hook that refused every `cd` chain would stop a builder running its checks in those projects. Refuse only a chain that holds both a `cd` and `git`.
2. **Only forms that ended a real trial and that no allow rule lifts.** Today that is two: `cd` with `git`, and a trailing `; echo $?`. Every form added is a copy of a Claude Code guard that can change with an update. The probe kit should check after each update that each one is still refused by Claude Code.
3. **No job lookup.** The reason can name the folder from the command itself, so the hook stays as cheap as it is.

**The reason, as I'd word it:**

> Don't `cd` before git: run `git -C <folder> …`. Your other commands still run.

The last sentence matters most. Both agents concluded that Bash was off.

## 2. Proposal 2: start the agent in its tree

**This is the root.** If a sub-agent starts in its tree, there is no `cd`, a project's checks run as its docs say, and a relative path lands in the tree and not in the owner's checkout.

**My expectation, from memory, is that it can't be done** for a tree the framework made: I know of no working-folder setting on the Agent tool or in a definition, and a sub-agent's folder is reset between its commands. So the probe may well say no. It is still worth an hour, because a yes removes this whole class.

**One question to add, which matters if the answer is no:** with an allow rule for a project's check command, does `cd <tree> && <that command>` run for a background agent? The fixture's tests can be started by path, so the trials never asked. If that chain is refused too, a job agent can't run the checks of any project that must be run from its own folder, and that has to be solved before real use, not found in it.

## 3. Proposals 3 and 4

- **3:** the line comes out, as agreed in advance.
- **4:** yes. The scorer passed a build that ran no check, because it scores only the hand-in. Add it.

**For the owner, noted only:** the framework also accepted that build, and by design. A report that says honestly "no check was run" is a valid report, and whether that is good enough is main's and the human's call. It must then be plain on the card the human sees. That belongs to the dispatch talk.

## 4. One more thing the two trials show

**Both builder runs spent their first try on length and location:**

| Run | Refused for |
|---|---|
| trial 1 | `summary` 168 characters against 55; four `at` written in words; one text of 210 against 200 |
| trial 2 | `summary` 186 against 55; four `at` written in words; one text of 203 against 200 |

The prose says of `summary` only "what you did, in one line", and of `at` only "where". The agent can't know the limit, so the first refusal is close to certain. The repair works, but a job has two tries, and this spends one every time. A second, real problem then ends the job.

**I'd not change anything yet:** two runs are two runs, and the counted runs exist to show exactly this. If it repeats, the fix I'd look at first carries no number: "`summary`: what you did, as a commit subject". The number would then stay in one place, the check.

## 5. The order I'd put to the owner

1. Take the conduct line out, and add the scorer's check.
2. Run the probe of proposal 2, with the added question.
3. If a sub-agent can start in its tree: that goes to the dispatch talk, and the hook's new refusals may not be needed at all.
4. If not: build proposal 1 within the three limits, with proof cases for both forms, for a plain `cd` chain passing untouched, and for main's own commands.
5. Rerun the two trials. The bar is unchanged: the reviewer hands in a real review, and the builder runs its checks.
