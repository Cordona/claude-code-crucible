# Testing: the untested line

One line per behaviour left untested:

```
Untested: <case> · reason: <reason> · risk: <risk accepted> · category: <security | persisted-data | concurrency | authentication | none> · proof: <test N | file:line | unproven>
```

Strict: every field present, in this order, with these labels. `category` takes one listed value, `none` when the case falls under no required category. `proof` names the test or the `file:line` showing the risk is covered or absent, or says `unproven`.
