---
name: crucible-grill
description: How main interviews a human who doesn't yet know what they want, a few questions at a time, until both share one understanding, recording each answer as a decision. Use when the human asks to be grilled, when the goal looks open and the human agrees to a grill, or to go on with a grill left open after a break. Writes the grill through its scripts. Not for finding out what already exists, or for writing the spec.
---

# Grill

A grill helps the human decide what they don't know yet: you ask, they decide, until you share one understanding. When the goal looks open, offer one, and start on the human's yes. The human asking to be grilled is also their yes to an effort for it, when none is open; inside an open effort, the grill joins it.

Read what is already known first, so no question asks a fact. Then ask in rounds: questions already open in the grill before new ones, a few at a time, none depending on another in the same round, each with your recommended answer and why. A question that follows from an answer names that question as its parent, so a changed answer sends it back to open. A round is a small card saying what the last answers settled, what this round is about, and how many questions are settled and open, followed by one question dialog. For example:

> Settled: a cron job runs the prune. This round: what happens on failure. 1 settled, 2 open.

Then the round's question dialog, as its AskUserQuestion input:

```json
{
  "questions": [
    {
      "header": "Failure",
      "question": "Should a failed prune email someone?",
      "multiSelect": false,
      "options": [
        {
          "label": "Yes (Recommended)",
          "description": "No one watches a cron job, so a failure would go unseen"
        },
        {
          "label": "No",
          "description": "Failures only show up in the logs"
        }
      ]
    }
  ]
}
```

A question with no real options, such as a name or a fact only the human holds, is asked in a plain sentence; never invent options to fit the dialog. When the human asks what a question means, explain in conversation.

Record only direct answers. A hedge, a question back, or a "yes, but" stays open, and a bare "yes" accepts your recommendation. A question that turned out wrong is dropped and asked again as a new one, with the old one as its parent. Drop what no longer matters, and defer what needs someone else. Never put a secret in a question or an answer: every agent reads the ended grill.

End when the human says you share one understanding. You may end with questions still open or deferred.

The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract.
