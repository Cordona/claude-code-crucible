# Read trackers: development

Apply after `SKILL.md`'s rules, when you read the context.

## Reporting

`standard-code-development-report` sets each item's shape.

- **A link you skipped** -> the report's `open` (`could_not`), its `ref` `links[<n>]` with the `<n>` you passed to `--link`, and its `text` the reason `SKILL.md` gives for that exit.

## Self-check before reporting

1. `read-link.sh --help` ran before the first link, and again only after its contract left your context.
2. Every tracker link was read through `read-link.sh`; no tracker command of your own ran, and none wrote to a tracker.
3. Each item `## Reporting` names is in the report.

A failed item: fix it, then check again, at most twice; then record it in the report's `open` as `could_not`.
