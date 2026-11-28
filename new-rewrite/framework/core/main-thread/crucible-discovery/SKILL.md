---
name: crucible-discovery
description: How main finds out what an effort's work is about, what it must achieve, what it must not break, and what already exists, before anything is specified or built. Use while building an effort's context, or when the human brings in material that may change what the work is about. Not for interviewing a human who doesn't yet know what they want, or for writing the spec.
---

# Discovery

Discovery is how you come to understand the work well enough to write it down: what it must achieve, what it must not break, and what already exists.

Read first, ask second. Read what the human points to and what you can find yourself, such as the files, the documents and the linked pages, so that no question asks a fact you could have looked up. Then ask the human only the facts the material can't answer, a few short questions at a time; a choice that changes the outcome goes to a gate.

Put what you find into the effort's context.

When two sources, or two things the human said, contradict each other in a way that changes the outcome (what is built, what it must do or must not break), keep both in their own words and ask the human which holds, one question per contradiction. Recommend the side the facts support, even when that is a source over the human's own words; the human settles it. A small mismatch, such as a wording, a name or a format, needs no question: the human's words win over a source, and their later word over an earlier one. For example, as the question's AskUserQuestion input:

```json
{
  "questions": [
    {
      "header": "Retention",
      "question": "The issue says prune after 30 days; you said 90. Which holds?",
      "multiSelect": false,
      "options": [
        {
          "label": "90 days (Recommended)",
          "description": "Your word is newer, and the issue predates the retention change"
        },
        {
          "label": "30 days",
          "description": "Keeps the issue as written; more data is deleted"
        }
      ]
    }
  ]
}
```

Discovery is done when the human confirms the goal and what must not break; where there is a context, that confirmation is their yes at its "done?" gate.
