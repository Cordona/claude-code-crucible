# Read trackers: development

## Self-check before reporting

1. `read-link.sh --help` ran before the first link, and again only after its contract left your context.
2. Every tracker link was read through `read-link.sh`; no tracker command of your own ran, and none wrote to a tracker.

A failed item: fix it, then check again, at most twice; then record it in the report's `open`, its `ref` `procedure-read-trackers`.
