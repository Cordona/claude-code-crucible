---
name: agent-report
description: What every report an agent writes has in common - one JSON object, and the forms a location takes. Loaded by agents through their frontmatter; never used directly.
user-invocable: false
---

# Agent report

- Write one JSON object to the report path.

## A location

Every `at` is one of these, or a JSON array of them, such as `["a.sh:3", "b.sh:7"]`:
- `path`: a whole file in the tree you were given;
- `path:N` or `path:N-M`: a line, or lines, in that tree;
- `-path:N`: a line as it was before the change, for a line the change deleted;
- `@<where>:path`, `@<where>:path:N`: a place in another repository, such as `@billing-api:src/Invoice.php:40`.

A path is relative to its root, and a line must exist. A place you would describe in words goes by its file and line. Something with no place in a file takes no `at`.

