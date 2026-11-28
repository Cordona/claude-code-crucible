# The step 4 fixes: the command hook and the owner's design for lengths. Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** rows P20a to P20d in `evidence/stop-hook-probe/results.md`, the text and summary rules in `builder-common.jq` and `reviewer-common.jq`, `working-commit.sh`, `trailers.sh`, and the contract of `commit-message.sh` with its subject rule.

**Not done:** I ran nothing and did not open the P20 logs; the rows are Dev Beta's reading of them. I did not read the tester's rules line by line, only that they have the same text rule.

## Verdict

**I approve both, with three conditions on the hook and three on the lengths.** None changes the design.

| Part | View |
|---|---|
| One hook that answers a job agent's ask on a compound command | **Yes.** Remove `refuse-denied-forms.sh` |
| The subject cut from the summary, the whole summary in the body | **Yes.** The cut belongs in `commit-message.sh` |
| No length ever fails an agent | **Yes.** Better than my margin |

## 1. The command hook

**P20 answers what I asked.** The refusal reaches the agent word for word, the agent acts on it, the human sees no prompt for it, and a plain command still reaches the human or the allow-list. This is the root I hoped for: the hook runs only when Claude Code is about to ask, so no list of forms has to follow Claude Code's updates.

**The message is approved as written:** "Run it as plain single commands, one per call. Your other commands still run." It names no plumbing.

**Remove `refuse-denied-forms.sh`.** Both of its forms are asks, so the new hook covers them. It also ran on every command; the new hook runs only on an ask.

**Three conditions:**

1. **Ignore what is inside quotes.** A builder's `sed -i 's|a|b|' file` or a commit message with a `;` in it is one plain command. Read as compound, it is refused with advice the agent can't follow, and the human never gets the question. Strip quoted text before looking for a chain, an assignment or a substitution.
2. **A job agent means an agent with an open job.** Use the one job lookup, as the write guard does. Claude Code's own helper agents also carry an agent id, and they must be left alone. An ask is rare, so the lookup's cost doesn't matter here.
3. **Leave pipes out,** as proposed. A pipe that asks does so because one side isn't allowed, and splitting it changes nothing.

**What the probe covered:** main in default mode, headless and interactive. That is the supported case. The record should say other modes are unprobed.

**Proof:** one runner case for the script alone, and the matrix cells that used the removed step rerun against the hook.

## 2. Lengths and the summary

### 2.1 No length check at all

**I agree, and it is the better answer.** My margin still had a number a model could miss. The owner's rule has none.

**What still bounds a text:** the one-line rule stays, as shape. A text can't be pasted output or a page.

**What I'd watch in the rerun:** the spread of lengths per field. If texts drift to paragraphs, the fix is in the prose, never a refusal.

### 2.2 The commit

**Sound.** Git reads trailers from the last paragraph only, so the summary in the body can't be mistaken for one, even when it starts with a word and a colon. The script that reads a working commit back takes the kind from the subject's prefix and the rest from trailers, so the cut doesn't touch it.

**Three conditions:**

1. **One home for the cut.** `commit-message.sh` owns the 72 and the `crucible(<kind>): ` prefix. If the commit step cuts the summary itself, both numbers live twice. So `commit-message.sh` takes the long text and makes the subject fit. Main's own commits keep today's strict rule: the cut applies only when the long text is given. This changes that script's input by one key, and the owner approves JSON shapes before they change.
2. **Cut at a word, and mark it.** The subject ends at the last whole word that fits, followed by "…", counted inside the 72. A reader of `git log --oneline` then knows there is more.
3. **The same shape always.** The body holds the whole summary even when it fits the subject. One shape is simpler to read back than two.

### 2.3 What goes and what stays

- **Goes:** the 200 limit in all three agents' rules, the reviewer's 1000 limit on long text, the summary's 55, and the number in the "summary is missing" line.
- **Stays:** blank text, more than one line, and the summary that starts with its own `fix:` prefix. These are shape, and an agent fixes them reliably. None of the three appears in run 3's refusals.

### 2.4 "The displays shorten"

No shared shortener exists today, and cards show totals, not texts. **Build one only where a text is really shown,** in the component that owns the cards, and say which views those are. Nothing to build ahead of a view that needs it.

### 2.5 The prose

Each definition says today "in one line". The target of about 200 characters is one clause in each of the three definitions, not in the shared skill. Those lines come to me before they run, with the others still owed: the three location lines, the tester's "applied" clause and the tester's mutation line.

## 3. The rerun

Unchanged from my last review: all 33, the two parked cases, the full interactive set. Report the number accepted at the first stop beside the bar of zero gave up. With lengths gone, I expect most to pass first time; if not, the flagged lines will say what the prose still misses.
