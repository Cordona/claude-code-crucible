---
name: crucible-gate
description: How main asks the human to decide, and shows a card before the question when one helps. Use whenever main asks the human a question with AskUserQuestion or shows a card for a decision. Hooks hold the question until the card is shown and check each question's shape. Not for how a card's content is produced.
---

# Gates

A gate is worth it for a decision that matters and that you initiate, for example: starting an effort, agreeing how to reach a goal, choosing what to act on, anything hard to undo.

A question whose answer changes the outcome is a gate when it is a choice between real options, even in the middle of other work; several go in one question dialog, up to four, behind one small card. An open question with no real options is asked plainly. Never ask for the go in passing, as an "OK to go ahead?" at the end of a message: if you need the human's go to start something, such as an effort, that is a decision and goes to a gate; if you don't need it, go on. Anything else that needs the human, such as a fact only they know, is asked in a plain sentence.

The human switches between several sessions and often arrives at this one cold. A gate's job is to let them decide fast and well: in one look they see what's at stake, what you recommend and why, and what the alternative costs.

## The card

Every gate starts with a card: what the human looks at before deciding. The card is a file, either one a script produced or a short one you write in your own words. Run `sh <this skill's folder>/scripts/main/show-card.sh <card file>`, end your turn with the card exactly as printed, and ask once told to. If your turn ended with the card and nothing told you to ask, the gate's hooks aren't running: at the human's next message, say so, suggest the install check in the framework's `install/` folder, and then ask.

## The question

Each question:

1. is built from this situation, every time;
2. puts the recommended option first, marked as in the example, with its why;
3. leaves room for the human's own words;
4. carries the deciding facts in the question, and an honest, objective recommendation that never hides the alternative.

For example, as the AskUserQuestion input, with the most options it takes (4). The dialog adds the fifth choice, the human's own words, by itself:

```json
{
  "questions": [
    {
      "header": "Next step",
      "question": "3 of the 5 steps are done. The other 2 depend on an answer from another team, expected tomorrow. How do we continue?",
      "multiSelect": false,
      "options": [
        {
          "label": "Wait for the answer (Recommended)",
          "description": "The answer may change the 2 steps, so waiting avoids redoing them"
        },
        {
          "label": "Continue on a guess",
          "description": "Faster, but the 2 steps may need redoing"
        },
        {
          "label": "Close the 3 done steps now",
          "description": "Banks the finished part; the other 2 wait as their own piece"
        },
        {
          "label": "Drop the 2 steps",
          "description": "Simplest, but the goal is only partly met"
        }
      ]
    }
  ]
}
```

A refusal says what's wrong: fix it and carry on.
