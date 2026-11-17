# Testing: the untested entry

One object in the test plan's `untested` list per behaviour left untested:

```json
{
  "id": "N-<n>",
  "case": "<case>",
  "reason": "<reason>",
  "risk": "<risk accepted>",
  "category": "<short text, such as security, persisted-data, concurrency, authentication or none>",
  "proof": "<a test | path:line | a pointer to another repo | unproven>",
  "recommend": "<test | waive>"
}
```

Strict: every field present, with these keys. `id` is `N-` and a number from 1, unique in the plan. `category` is any short text naming the case's category; the values above are common examples, not a fixed list, with `none` when the case falls under no required category. `proof` names the test, the `path:line` or the other repo's test showing the risk is covered or absent, or says `unproven`. `recommend` is `test` or `waive`: what the human is advised to choose.
