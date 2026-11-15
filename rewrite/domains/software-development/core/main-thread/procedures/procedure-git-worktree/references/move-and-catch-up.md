# Move and catch-up

Read when `flow-code-build` points a seat at another commit for new work (a move), or brings a commit into a seat's branch to take in other work (a catch-up). The commit is any commit main picks: a branch it cut, the remote main, a release branch, another MR. Pass it by its name (a branch, a remote-tracking branch such as `origin/main`, a tag) or its sha, and never resolve it with git: the script resolves it in the seat's repository. A remote ref is fetched first, on the human's ask (Never). Treat a non-zero exit as a refusal (Always).

## Move

Only after the human's yes to where the new work starts (Never): `sh "<scripts>/seats/seat-move.sh" --effort '<effort folder>' --seat '<seat>' --to '<commit or ref>'`, adding `--follows '<name>'` only when the human knows the commit by another name than the one passed.

- **Refused:** a non-zero exit, a refusal (Always).
- **Moved:** its stdout is the seat's JSON line, for the flow, then the card `seat-moved`.

## Catch-up

`sh "<scripts>/merge/catch-up.sh" --effort '<effort folder>' --seat '<seat>' --with '<commit or ref>'`, adding `--label '<name>'` only when the human knows the commit by another name. Its stdout is one JSON line, then its cards:

- **`reason` `in_sync`:** the seat already holds the commit, said by the line `in_sync`.
- **`caught_up` `true`:** a clean merge on the seat's branch, said by the card `caught-up`.
- **`reason` `conflict`:** the merge is under way in the seat's worktree, said by the card `conflict`. Hand its `message` to `flow-code-build`, which sends it to the seat's developer through `procedure-seat-run`'s Changes; the worktree stays mid-merge until they resolve it (Never).
