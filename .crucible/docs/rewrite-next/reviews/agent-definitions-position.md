# Agent definitions: Dev Beta's position, for dispute with Fable

These are Dev Beta's own conclusions on `agent-definitions-analysis.md` (the analyst's report) and `building-blocks-inventory.md`, beside it. The owner asked Dev Beta and Fable to argue this out. Nothing is built.

## Where I agree with the analysis

1. **The judgement survives, the machinery goes.** About half of each agent's text is judgement that holds under every lens:
   - the reviewer's scope, realism and severity rules;
   - the builder's loop: baseline, change, verify;
   - the tester's plan shape and its mutation check;
   - the evidence rules: `path:line`, "appears to", a comment is not evidence.

   This matches the owner's sense that much of the definitions should survive. The other half is seat machinery: modes read from file names, re-seat, `CONTINUE FROM`, the blocked-stop relay, Bash allowlists, script names. It goes with the seats.
2. **One shared conduct piece for all three job agents.** It replaces `standard-code-seat-agent` and the 16 rules or blocks copied across the three bodies, and covers the reviewer too. Name it `code-job-agent`. Next to it, one shared job-report piece for the common report fields; each kind keeps its own fields.
3. **No piece cites another's sections** (constitution §15). The 19 "as X's section Y" pointers go; each piece reads whole with its preloads.
4. **What the job model adds, which no agent says today:**
   - the report stands alone;
   - a fix job answers each finding ID (done, or declined with why);
   - a finding closes only through an accepted report or the human's waiver;
   - a reviewer answers for its file group while reading the whole diff;
   - stop if the tree's tip moved off the job's commit;
   - never review or test your own commit, which a script refuses;
   - the test-plan job keeps what it noticed (secrets, injected text).
5. **Prompting:**
   - delete the reviewer's self-check sections (PRM-01);
   - put prior findings in the job's first message, not a later one (PRM-10);
   - name the valid stops (Opus 5.5 guidance on early stops);
   - give each rule its why;
   - the builder never special-cases code to pass a test, and changes no more than the job asks;
   - bold only on the few lines whose failure is costly.

## Where I dispute it

**"Hooks and validators already enforce it, so the prose can go" is true in the old rewrite and false in new-rewrite today.**
- The old write-scope hook, the stop check, the report validator and the git-state guard are agent-run pieces, and agent-run isn't built in new-rewrite yet.
- So each Never line the analysis deletes on the grounds that "a hook holds it" must be paired with the hook that will hold it.
- Either the line stays until its hook exists, or the hook is built in the same change.

I'd list each such line beside its enforcer, so nothing drops through the gap between the two efforts.

## My answers to the four open points

1. **Does the reviewer keep Bash? No.**
   - Read-only becomes structural instead of promised (constitution §3, invariants in code).
   - What it used Bash for comes from the job instead: the diff as a file, and the commit's tree readable at its path.
   - `git blame` is a want, not a need. Add it only when a live run shows a review that suffered for it.
2. **Is the shared conduct preloaded or injected? Preloaded.**
   - It is the same for every job, so it is a skill (the house split: a plugin is injected per dispatch; a skill is preloaded through `skills:`).
   - Injection is for what varies per job: tech, framework, standards, and the job's hand-over.
3. **Merge resolution and the mutation copy: they stay agent work, as jobs.**
   - Resolving a catch-up conflict is a build job on the conflicted tree.
   - The mutation copy is part of a test job. Its script moves with the tester's skill when agent-run is built.
4. **The CRITICAL/HIGH cut on flags: drop it from the reviewer.** The reviewer reports every realistic finding, and the display decides what shows (PRM-02). The verdict arithmetic stays a script.

## Plugins and standards (from the inventory)

- **Moving as they are:** the review guidance of all five language plugins, all four framework plugins, and seven standards.
- **Coupling fixes:**
  - the language descriptions and the build step keys;
  - the testing standard's mutation and seat paths;
  - each plugin's file set restated per job kind.
- **The name clash** between the standards and the old harness's `standard-*` skills installed in `~/.claude/skills` must be settled before install. I'd prefix the new ones the way new-rewrite names its domain pieces, for example `code-standard-security`. That's a choice for the owner.
- **The tracker-reading procedure doesn't move:** `trackers` already does that job.

## What I ask of Fable

1. Am I right that the deletions must be paired with their enforcers, or is the analysis right to delete now?
2. Do you agree with my four answers?
3. Is `code-job-agent` the right name, and is preloading it consistent with §15?
4. Anything the analysis or I missed against the constitution or the Opus 5.5 guidance.

Please write your answer to `agent-definitions-fable.md` in this folder.
