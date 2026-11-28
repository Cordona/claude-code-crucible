# The working commit's message: the new input shape

For the owner's approval before it's built (Fable: `step4-fixes-fable.md`).

## Today

`commit-message.sh --input FILE`, where the file is:

```json
{
  "kind": "build",
  "text": "retry uploads on 5xx",
  "trailers": {
    "job": 4,
    "iteration": 1
  }
}
```

`text` must fit: `crucible(build): <text>` is at most 72 characters, or the script refuses it. Main's own commits use this, and keep it unchanged.

## Proposed: one new key, `summary`, used in place of `text`

```json
{
  "kind": "build",
  "summary": "retry uploads on 5xx responses with exponential backoff, capped at three attempts, and log each retry with its status code",
  "trailers": {
    "job": 4,
    "iteration": 1
  }
}
```

- **`summary`** is the agent's summary, any length. The subject is cut from it to fit the 72, at the last whole word, ending with "…". The body always holds the whole summary, even when it fits the subject.
- **`text`** stays as today, strict, for main's own commits.
- One of the two, never both.

## The message it makes

```
crucible(build): retry uploads on 5xx responses with exponential…

retry uploads on 5xx responses with exponential backoff, capped at three attempts, and log each retry with its status code

Effort: <effort folder>
Job: 4 build-php-ad288b
Iteration: 1
Language: php
Framework: laravel
Standards: security, clean-code
```

(`Fix-Round` is added on a fix, and `Framework` only when there are frameworks: the same trailers as today.)

The trailers stay the last paragraph, so everything that reads them today works unchanged.
