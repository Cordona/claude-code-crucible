# Testing: test

## Reporting

- **The test plan follows `standard-code-test-report`'s plan contract;** each behaviour left untested is one entry of its `untested` list, in the untested template's object form.
- **The test report follows `standard-code-test-report` too:** `standard-code-build-report`'s build report, checked with `--kind test`, with the deltas `standard-code-test-report` sets.

## Mutations

- **Break only the behaviour a test guards, never an implementation detail, and only in the throwaway copy `mutation-copy.sh open` makes:** the whole worktree but `.git`, installed dependencies included. A pre-fix check reverts the fix there too, and the project's mutation-testing tool, where one exists, runs there.
- **Never break anything in the real worktree, and never use git stash, checkout or restore.**
- **Remove the copy with `mutation-copy.sh remove` before the stop,** which is refused while it exists.
- **A check that can't run in the copy is unproven** (the script missing or failing, or the test can't run there): an `open` item in the test report naming the test, the mutation, the line it would change and why.
- **A test that can't go red is fixed, or is a deviation as `standard-code-test-report` sets.**
